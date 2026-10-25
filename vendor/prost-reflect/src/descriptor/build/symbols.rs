use crate::descriptor::{
    build::{
        join_path,
        visit::{visit, Visitor},
        DescriptorPoolOffsets,
    },
    error::{DescriptorError, DescriptorErrorKind, Label},
    find_enum_proto, find_message_proto, tag,
    types::{
        DescriptorProto, EnumDescriptorProto, EnumValueDescriptorProto, FieldDescriptorProto,
        FileDescriptorProto, MethodDescriptorProto, OneofDescriptorProto, ServiceDescriptorProto,
    },
    DefaultSymbolVisibility, DescriptorPoolInner, EnforceNamingStyle, EnumIndex, EnumValueIndex,
    ExtensionIndex, Features, FieldIndex, FileIndex, KindIndex, MessageIndex, MethodIndex,
    OneofIndex, ServiceIndex, SymbolVisibility,
};

/// The last field number of the range protobuf reserves for its own use, as protoc's
/// namespacing rule for STRICT visibility compares it.
const LAST_RESERVED_NUMBER: i32 = 19_999;

impl DescriptorPoolInner {
    /// Checks the rules edition 2024 adds for symbols, in protoc's order: a message or enum used
    /// from another file must be exported; then, when nothing else is wrong, names must follow
    /// the style the `enforce_naming_style` feature asks for (if the pool enforces it), and
    /// nested types must not be exported under STRICT visibility.
    ///
    /// This runs after features are resolved, since both rules depend on them.
    pub(super) fn check_symbols(
        &mut self,
        offsets: DescriptorPoolOffsets,
    ) -> Result<(), DescriptorError> {
        let files: Vec<FileDescriptorProto> = self.files[offsets.file as usize..]
            .iter()
            .map(|file| file.raw.clone())
            .collect();

        let mut visibility = VisibilityChecker {
            pool: self,
            errors: Vec::new(),
        };
        visit(offsets, &files, &mut visibility);
        if !visibility.errors.is_empty() {
            return Err(DescriptorError::new(visibility.errors));
        }

        if self.enforce_naming_style {
            let mut naming = NamingStyleChecker {
                pool: self,
                errors: Vec::new(),
            };
            visit(offsets, &files, &mut naming);
            if !naming.errors.is_empty() {
                return Err(DescriptorError::new(naming.errors));
            }
        }

        let mut strict = StrictVisibilityChecker {
            pool: self,
            errors: Vec::new(),
        };
        visit(offsets, &files, &mut strict);
        if !strict.errors.is_empty() {
            return Err(DescriptorError::new(strict.errors));
        }

        Ok(())
    }
}

struct VisibilityChecker<'a> {
    pool: &'a DescriptorPoolInner,
    errors: Vec<DescriptorErrorKind>,
}

impl VisibilityChecker<'_> {
    /// Reports `kind`, referenced from `file` at `path`, if it is a message or enum defined in
    /// another file and not exported. `usage` describes the reference, when it is not a type.
    fn check(&mut self, file: FileIndex, path: &[i32], kind: KindIndex, usage: &str) {
        let (id, keyword, features, nested) = match kind {
            KindIndex::Message(index) | KindIndex::Group(index) => {
                let message = &self.pool.messages[index as usize];
                let raw = find_message_proto(
                    &self.pool.files[message.id.file as usize].raw,
                    &message.id.path,
                );
                (
                    &message.id,
                    raw.visibility,
                    message.features,
                    message.parent.is_some(),
                )
            }
            KindIndex::Enum(index) => {
                let enum_ = &self.pool.enums[index as usize];
                let raw =
                    find_enum_proto(&self.pool.files[enum_.id.file as usize].raw, &enum_.id.path);
                (
                    &enum_.id,
                    raw.visibility,
                    enum_.features,
                    enum_.parent.is_some(),
                )
            }
            _ => return,
        };
        let keyword = SymbolVisibility::from_keyword(keyword);
        if id.file == file
            || SymbolVisibility::resolve(keyword, features, nested) == SymbolVisibility::Export
        {
            return;
        }

        let reason = if keyword == Some(SymbolVisibility::Local) {
            "It is explicitly marked 'local'".to_owned()
        } else {
            format!(
                "It defaulted to local from file-level 'option \
                 features.default_symbol_visibility = {};'",
                default_symbol_visibility_name(features.default_symbol_visibility)
            )
        };
        let files = &self.pool.files;
        self.errors.push(DescriptorErrorKind::NotVisible {
            message: format!(
                "Symbol \"{}\", defined in \"{}\"{usage} is not visible from \"{}\". {reason} and \
                 cannot be accessed outside its own file",
                id.full_name,
                files[id.file as usize].raw.name(),
                files[file as usize].raw.name(),
            ),
            found: Label::new(files, "found here", file, path.into()),
            defined: Label::new(files, "defined here", id.file, id.path.clone()),
        });
    }
}

fn default_symbol_visibility_name(value: DefaultSymbolVisibility) -> &'static str {
    match value {
        DefaultSymbolVisibility::ExportAll => "EXPORT_ALL",
        DefaultSymbolVisibility::ExportTopLevel => "EXPORT_TOP_LEVEL",
        DefaultSymbolVisibility::LocalAll => "LOCAL_ALL",
        DefaultSymbolVisibility::Strict => "STRICT",
    }
}

impl Visitor for VisibilityChecker<'_> {
    fn visit_field(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        message: MessageIndex,
        index: FieldIndex,
        _: &FieldDescriptorProto,
    ) {
        let kind = self.pool.messages[message as usize].fields[index as usize].kind;
        self.check(file, &join_path(path, &[tag::field::TYPE_NAME]), kind, "");
    }

    fn visit_extension(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        _: Option<MessageIndex>,
        index: ExtensionIndex,
        _: &FieldDescriptorProto,
    ) {
        let extension = &self.pool.extensions[index as usize];
        let (extendee, kind) = (extension.extendee, extension.kind);
        self.check(
            file,
            &join_path(path, &[tag::field::EXTENDEE]),
            KindIndex::Message(extendee),
            " target of extend",
        );
        self.check(file, &join_path(path, &[tag::field::TYPE_NAME]), kind, "");
    }

    fn visit_method(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        service: ServiceIndex,
        index: MethodIndex,
        _: &MethodDescriptorProto,
    ) {
        let method = &self.pool.services[service as usize].methods[index as usize];
        let (input, output) = (method.input, method.output);
        self.check(
            file,
            &join_path(path, &[tag::method::INPUT_TYPE]),
            KindIndex::Message(input),
            "",
        );
        self.check(
            file,
            &join_path(path, &[tag::method::OUTPUT_TYPE]),
            KindIndex::Message(output),
            "",
        );
    }
}

/// Checks names against the `STYLE2024` naming style, as protoc does.
struct NamingStyleChecker<'a> {
    pool: &'a DescriptorPoolInner,
    errors: Vec<DescriptorErrorKind>,
}

impl NamingStyleChecker<'_> {
    fn check(
        &mut self,
        features: Features,
        file: FileIndex,
        path: &[i32],
        what: &str,
        name: &str,
        style: fn(&str) -> Result<(), &'static str>,
    ) {
        if features.enforce_naming_style != EnforceNamingStyle::Style2024 || name.is_empty() {
            return;
        }
        if let Err(problem) = style(name) {
            self.errors.push(DescriptorErrorKind::NamingStyle {
                message: format!(
                    "{what} name {name} {problem} (features.enforce_naming_style = STYLE_LEGACY \
                     can be used to opt out of this check)"
                ),
                found: Label::new(&self.pool.files, "found here", file, path.into()),
            });
        }
    }
}

impl Visitor for NamingStyleChecker<'_> {
    fn visit_file(&mut self, path: &[i32], index: FileIndex, file: &FileDescriptorProto) {
        let features = self.pool.files[index as usize].features;
        self.check(
            features,
            index,
            &join_path(path, &[tag::file::PACKAGE]),
            "Package",
            file.package(),
            lower_snake_case,
        );
    }

    fn visit_message(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        _: Option<MessageIndex>,
        index: MessageIndex,
        message: &DescriptorProto,
    ) {
        let features = self.pool.messages[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::message::NAME]),
            "Message",
            message.name(),
            title_case,
        );
    }

    fn visit_field(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        message: MessageIndex,
        index: FieldIndex,
        field: &FieldDescriptorProto,
    ) {
        let features = self.pool.messages[message as usize].fields[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::field::NAME]),
            "Field",
            field.name(),
            lower_snake_case,
        );
    }

    fn visit_extension(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        _: Option<MessageIndex>,
        index: ExtensionIndex,
        extension: &FieldDescriptorProto,
    ) {
        let features = self.pool.extensions[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::field::NAME]),
            "Field",
            extension.name(),
            lower_snake_case,
        );
    }

    fn visit_oneof(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        message: MessageIndex,
        index: OneofIndex,
        oneof: &OneofDescriptorProto,
    ) {
        let features = self.pool.messages[message as usize].oneofs[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::oneof::NAME]),
            "Oneof",
            oneof.name(),
            lower_snake_case,
        );
    }

    fn visit_enum(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        _: Option<MessageIndex>,
        index: EnumIndex,
        enum_: &EnumDescriptorProto,
    ) {
        let features = self.pool.enums[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::enum_::NAME]),
            "Enum",
            enum_.name(),
            title_case,
        );
    }

    fn visit_enum_value(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        enum_: EnumIndex,
        index: EnumValueIndex,
        value: &EnumValueDescriptorProto,
    ) {
        let features = self.pool.enums[enum_ as usize].values[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::enum_value::NAME]),
            "Enum value",
            value.name(),
            upper_snake_case,
        );
    }

    fn visit_service(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        index: ServiceIndex,
        service: &ServiceDescriptorProto,
    ) {
        let features = self.pool.services[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::service::NAME]),
            "Service",
            service.name(),
            title_case,
        );
    }

    fn visit_method(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        service: ServiceIndex,
        index: MethodIndex,
        method: &MethodDescriptorProto,
    ) {
        let features = self.pool.services[service as usize].methods[index as usize].features;
        self.check(
            features,
            file,
            &join_path(path, &[tag::method::NAME]),
            "Method",
            method.name(),
            title_case,
        );
    }
}

/// Whether `name` has a leading or trailing underscore, or an underscore not followed by a
/// letter.
fn has_bad_underscores(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.first() == Some(&b'_') || bytes.last() == Some(&b'_') {
        return true;
    }
    bytes
        .windows(2)
        .any(|pair| pair[0] == b'_' && !pair[1].is_ascii_alphabetic())
}

fn title_case(name: &str) -> Result<(), &'static str> {
    if !name.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err("should be TitleCase");
    }
    if !name.as_bytes()[0].is_ascii_uppercase() {
        return Err("should begin with a capital letter");
    }
    Ok(())
}

fn lower_snake_case(name: &str) -> Result<(), &'static str> {
    if !name
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'.')
    {
        return Err("should be lower_snake_case");
    }
    if !name.as_bytes()[0].is_ascii_lowercase() {
        return Err("should begin with a lower case letter");
    }
    if has_bad_underscores(name) {
        return Err("contains style violating underscores");
    }
    Ok(())
}

fn upper_snake_case(name: &str) -> Result<(), &'static str> {
    if !name
        .bytes()
        .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
    {
        return Err("should be UPPER_SNAKE_CASE");
    }
    if !name.as_bytes()[0].is_ascii_uppercase() {
        return Err("should begin with an upper case letter");
    }
    if has_bad_underscores(name) {
        return Err("contains style violating underscores");
    }
    Ok(())
}

/// Checks that nested messages and enums are not exported under STRICT visibility, except an
/// enum namespaced in a local top-level message that reserves its field numbers.
struct StrictVisibilityChecker<'a> {
    pool: &'a DescriptorPoolInner,
    errors: Vec<DescriptorErrorKind>,
}

impl StrictVisibilityChecker<'_> {
    fn error(&mut self, file: FileIndex, path: &[i32], message: String) {
        self.errors.push(DescriptorErrorKind::InvalidFeature {
            message,
            found: Label::new(&self.pool.files, "found here", file, path.into()),
        });
    }

    /// Whether `enum_` is nested in a message used only as a namespace: a top-level message,
    /// local by keyword or by default, with a single reserved range starting at 1 (or ending at
    /// the last reserved number).
    fn is_namespace_enum(&self, enum_: EnumIndex) -> bool {
        let enum_inner = &self.pool.enums[enum_ as usize];
        let Some(container) = enum_inner.parent else {
            return false;
        };
        let container = &self.pool.messages[container as usize];
        if container.parent.is_some() {
            return false;
        }
        let raw = find_message_proto(
            &self.pool.files[container.id.file as usize].raw,
            &container.id.path,
        );

        let default_to_local = matches!(
            enum_inner.features.default_symbol_visibility,
            DefaultSymbolVisibility::Strict | DefaultSymbolVisibility::LocalAll
        );
        let is_local = match SymbolVisibility::from_keyword(raw.visibility) {
            Some(keyword) => keyword == SymbolVisibility::Local,
            None => default_to_local,
        };
        if !is_local || raw.reserved_range.len() != 1 {
            return false;
        }
        let range = &raw.reserved_range[0];
        range.start() == 1 || range.end() == LAST_RESERVED_NUMBER
    }
}

impl Visitor for StrictVisibilityChecker<'_> {
    fn visit_message(
        &mut self,
        path: &[i32],
        full_name: &str,
        file: FileIndex,
        parent: Option<MessageIndex>,
        index: MessageIndex,
        message: &DescriptorProto,
    ) {
        if parent.is_some()
            && SymbolVisibility::from_keyword(message.visibility) == Some(SymbolVisibility::Export)
            && self.pool.messages[index as usize]
                .features
                .default_symbol_visibility
                == DefaultSymbolVisibility::Strict
        {
            self.error(
                file,
                path,
                format!(
                    "\"{full_name}\" is a nested message and cannot be `export` with STRICT \
                     default_symbol_visibility. It must be moved to top-level, ideally in its \
                     own file in order to be `export`."
                ),
            );
        }
    }

    fn visit_enum(
        &mut self,
        path: &[i32],
        full_name: &str,
        file: FileIndex,
        parent: Option<MessageIndex>,
        index: EnumIndex,
        enum_: &EnumDescriptorProto,
    ) {
        if parent.is_some()
            && SymbolVisibility::from_keyword(enum_.visibility) == Some(SymbolVisibility::Export)
            && self.pool.enums[index as usize]
                .features
                .default_symbol_visibility
                == DefaultSymbolVisibility::Strict
            && !self.is_namespace_enum(index)
        {
            self.error(
                file,
                path,
                format!(
                    "\"{full_name}\" is a nested enum and cannot be marked `export` with STRICT \
                     default_symbol_visibility. It must be moved to top-level, ideally in its \
                     own file in order to be `export`. For C++ namespacing of enums in a \
                     messages use: `local message <OuterNamespace> {{ export enum {full_name} \
                     {{...}} reserved 1 to max; }}`"
                ),
            );
        }
    }
}
