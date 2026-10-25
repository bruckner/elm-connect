use crate::descriptor::{
    build::{
        join_path,
        visit::{visit, Visitor},
        DescriptorPoolOffsets,
    },
    error::{DescriptorError, DescriptorErrorKind, Label},
    features::FeatureSetProto,
    find_message_proto, tag,
    types::{
        field_descriptor_proto, DescriptorProto, EnumDescriptorProto, EnumValueDescriptorProto,
        FieldDescriptorProto, FileDescriptorProto, MethodDescriptorProto, OneofDescriptorProto,
        ServiceDescriptorProto,
    },
    Cardinality, DescriptorPoolInner, Edition, EnumIndex, EnumType, EnumValueIndex, ExtensionIndex,
    Features, FieldIndex, FieldPresence, FileIndex, KindIndex, MessageEncoding, MessageIndex,
    MethodIndex, OneofIndex, RepeatedFieldEncoding, ServiceIndex,
};

impl DescriptorPoolInner {
    /// Resolves the features of every descriptor in the new files, then applies them: for
    /// editions files, the field properties that proto2 and proto3 derive from the syntax
    /// (presence, packing, group encoding, required) are derived from the features, and the
    /// rules protoc enforces on features are checked.
    ///
    /// This runs after options are resolved, since features are options.
    pub(super) fn resolve_features(
        &mut self,
        offsets: DescriptorPoolOffsets,
    ) -> Result<(), DescriptorError> {
        // The visitors read the files' resolved options while updating the pool.
        let files: Vec<FileDescriptorProto> = self.files[offsets.file as usize..]
            .iter()
            .map(|file| file.raw.clone())
            .collect();

        let mut resolver = FeatureResolver {
            pool: self,
            errors: Vec::new(),
        };
        visit(offsets, &files, &mut resolver);
        if !resolver.errors.is_empty() {
            return Err(DescriptorError::new(resolver.errors));
        }

        let mut checker = EditionsVisitor {
            pool: self,
            errors: Vec::new(),
        };
        visit(offsets, &files, &mut checker);
        if !checker.errors.is_empty() {
            return Err(DescriptorError::new(checker.errors));
        }

        Ok(())
    }
}

struct FeatureResolver<'a> {
    pool: &'a mut DescriptorPoolInner,
    errors: Vec<DescriptorErrorKind>,
}

impl FeatureResolver<'_> {
    /// Merges the features set in `options` (an encoded options message whose `features` field
    /// is numbered `features_tag`) over `parent`.
    fn resolve(
        &mut self,
        parent: Features,
        file: FileIndex,
        path: &[i32],
        options_tag: i32,
        options: Option<&[u8]>,
        features_tag: u32,
    ) -> Features {
        let Some(set) = options.and_then(|o| FeatureSetProto::from_options(o, features_tag)) else {
            return parent;
        };

        let edition = self.pool.files[file as usize].edition;
        let options_path = join_path(path, &[options_tag, features_tag as i32]);
        if edition.is_legacy() {
            self.error(
                file,
                &options_path,
                "features are only valid under editions".to_owned(),
            );
            return parent;
        }

        if set.enforce_naming_style.is_some() || set.default_symbol_visibility.is_some() {
            let name = if set.enforce_naming_style.is_some() {
                "enforce_naming_style"
            } else {
                "default_symbol_visibility"
            };
            self.error(
                file,
                &options_path,
                format!(
                    "feature 'google.protobuf.FeatureSet.{name}' wasn't introduced until edition \
                     2024 and can't be used in edition {edition}"
                ),
            );
        }

        if let Some((feature, entity)) = unsupported_target(&set, features_tag) {
            self.error(
                file,
                &options_path,
                format!(
                    "option google.protobuf.FeatureSet.{feature} cannot be set on an entity of \
                     type `{entity}`"
                ),
            );
        }

        match parent.merge(&set) {
            Ok(features) => features,
            Err((name, value)) => {
                self.error(
                    file,
                    &options_path,
                    format!("feature '{name}' must resolve to a known value, found {value}"),
                );
                parent
            }
        }
    }

    fn error(&mut self, file: FileIndex, path: &[i32], message: String) {
        self.errors.push(DescriptorErrorKind::InvalidFeature {
            message,
            found: feature_label(&self.pool.files, file, path),
        });
    }
}

impl Visitor for FeatureResolver<'_> {
    fn visit_file(&mut self, path: &[i32], index: FileIndex, file: &FileDescriptorProto) {
        let edition = self.pool.files[index as usize].edition;
        let features = self.resolve(
            Features::defaults(edition),
            index,
            path,
            tag::file::OPTIONS,
            file.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::FILE,
        );
        if !edition.is_legacy() && features.field_presence == FieldPresence::LegacyRequired {
            self.error(
                index,
                &join_path(path, &[tag::file::OPTIONS, tag::features::FILE as i32]),
                "required presence can't be specified by default".to_owned(),
            );
        }
        self.pool.files[index as usize].features = features;
    }

    fn visit_message(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        parent: Option<MessageIndex>,
        index: MessageIndex,
        message: &DescriptorProto,
    ) {
        let parent = match parent {
            Some(parent) => self.pool.messages[parent as usize].features,
            None => self.pool.files[file as usize].features,
        };
        let features = self.resolve(
            parent,
            file,
            path,
            tag::message::OPTIONS,
            message.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::MESSAGE,
        );
        self.pool.messages[index as usize].features = features;
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
        let parent = self.pool.messages[message as usize].features;
        let features = self.resolve(
            parent,
            file,
            path,
            tag::oneof::OPTIONS,
            oneof.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::ONEOF,
        );
        self.pool.messages[message as usize].oneofs[index as usize].features = features;
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
        let message_inner = &self.pool.messages[message as usize];
        let parent = match message_inner.fields[index as usize].oneof {
            Some(oneof) => message_inner.oneofs[oneof as usize].features,
            None => message_inner.features,
        };
        let features = self.resolve(
            parent,
            file,
            path,
            tag::field::OPTIONS,
            field.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::FIELD,
        );
        let features =
            infer_legacy_features(self.pool.files[file as usize].edition, field, features);
        self.pool.messages[message as usize].fields[index as usize].features = features;
    }

    fn visit_extension(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        parent: Option<MessageIndex>,
        index: ExtensionIndex,
        extension: &FieldDescriptorProto,
    ) {
        let parent = match parent {
            Some(parent) => self.pool.messages[parent as usize].features,
            None => self.pool.files[file as usize].features,
        };
        let features = self.resolve(
            parent,
            file,
            path,
            tag::field::OPTIONS,
            extension.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::FIELD,
        );
        let features =
            infer_legacy_features(self.pool.files[file as usize].edition, extension, features);
        self.pool.extensions[index as usize].features = features;
    }

    fn visit_enum(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        parent: Option<MessageIndex>,
        index: EnumIndex,
        enum_: &EnumDescriptorProto,
    ) {
        let parent = match parent {
            Some(parent) => self.pool.messages[parent as usize].features,
            None => self.pool.files[file as usize].features,
        };
        let features = self.resolve(
            parent,
            file,
            path,
            tag::enum_::OPTIONS,
            enum_.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::ENUM,
        );
        self.pool.enums[index as usize].features = features;
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
        let parent = self.pool.enums[enum_ as usize].features;
        let features = self.resolve(
            parent,
            file,
            path,
            tag::enum_value::OPTIONS,
            value.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::ENUM_VALUE,
        );
        self.pool.enums[enum_ as usize].values[index as usize].features = features;
    }

    fn visit_service(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        index: ServiceIndex,
        service: &ServiceDescriptorProto,
    ) {
        let parent = self.pool.files[file as usize].features;
        let features = self.resolve(
            parent,
            file,
            path,
            tag::service::OPTIONS,
            service.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::SERVICE,
        );
        self.pool.services[index as usize].features = features;
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
        let parent = self.pool.services[service as usize].features;
        let features = self.resolve(
            parent,
            file,
            path,
            tag::method::OPTIONS,
            method.options.as_ref().map(|o| o.encoded.as_slice()),
            tag::features::METHOD,
        );
        self.pool.services[service as usize].methods[index as usize].features = features;
    }
}

/// The first feature in `set` whose `targets` (in descriptor.proto) exclude the entity whose
/// options hold `features` as field `features_tag`, and that entity's name.
fn unsupported_target(
    set: &FeatureSetProto,
    features_tag: u32,
) -> Option<(&'static str, &'static str)> {
    let entity = match features_tag {
        tag::features::FILE => return None,
        tag::features::MESSAGE => "message",
        tag::features::FIELD => "field",
        tag::features::ONEOF => "oneof",
        tag::features::ENUM => "enum",
        tag::features::ENUM_VALUE => "enum entry",
        tag::features::SERVICE => "service",
        tag::features::METHOD => "method",
        _ => return None,
    };
    let targets: [(&'static str, bool, &[&str]); 6] = [
        ("field_presence", set.field_presence.is_some(), &["field"]),
        ("enum_type", set.enum_type.is_some(), &["enum"]),
        (
            "repeated_field_encoding",
            set.repeated_field_encoding.is_some(),
            &["field"],
        ),
        ("utf8_validation", set.utf8_validation.is_some(), &["field"]),
        (
            "message_encoding",
            set.message_encoding.is_some(),
            &["field"],
        ),
        (
            "json_format",
            set.json_format.is_some(),
            &["message", "enum"],
        ),
    ];
    targets
        .into_iter()
        .find(|(_, is_set, allowed)| *is_set && !allowed.contains(&entity))
        .map(|(feature, _, _)| (feature, entity))
}

/// The features a proto2 or proto3 field's declaration implies, as protoc infers them: `required`
/// is required presence, a group is delimited, and the `packed` option sets the encoding.
fn infer_legacy_features(
    edition: Edition,
    field: &FieldDescriptorProto,
    mut features: Features,
) -> Features {
    if !edition.is_legacy() {
        return features;
    }
    if field.label() == field_descriptor_proto::Label::Required {
        features.field_presence = FieldPresence::LegacyRequired;
    }
    if field.r#type() == field_descriptor_proto::Type::Group {
        features.message_encoding = MessageEncoding::Delimited;
    }
    match field.options.as_ref().and_then(|o| o.value.packed) {
        Some(true) => features.repeated_field_encoding = RepeatedFieldEncoding::Packed,
        Some(false) if edition == Edition::Proto3 => {
            features.repeated_field_encoding = RepeatedFieldEncoding::Expanded
        }
        _ => (),
    }
    features
}

/// Applies resolved features to the fields and enums of editions files, and checks protoc's
/// rules for editions declarations.
struct EditionsVisitor<'a> {
    pool: &'a mut DescriptorPoolInner,
    errors: Vec<DescriptorErrorKind>,
}

impl EditionsVisitor<'_> {
    fn is_editions(&self, file: FileIndex) -> bool {
        !self.pool.files[file as usize].edition.is_legacy()
    }

    fn error(&mut self, file: FileIndex, path: &[i32], message: impl Into<String>) {
        self.errors.push(DescriptorErrorKind::InvalidFeature {
            message: message.into(),
            found: Label::new(&self.pool.files, "found here", file, path.into()),
        });
    }

    fn feature_error(&mut self, file: FileIndex, path: &[i32], message: impl Into<String>) {
        let found = feature_label(
            &self.pool.files,
            file,
            &join_path(path, &[tag::field::OPTIONS, tag::features::FIELD as i32]),
        );
        self.errors.push(DescriptorErrorKind::InvalidFeature {
            message: message.into(),
            found,
        });
    }

    fn is_map_entry(&self, message: MessageIndex) -> bool {
        let message = &self.pool.messages[message as usize];
        find_message_proto(
            &self.pool.files[message.id.file as usize].raw,
            &message.id.path,
        )
        .options
        .as_ref()
        .is_some_and(|o| o.value.map_entry())
    }

    /// The checks protoc applies to every field and extension of an editions file, before any
    /// that depend on where the field is declared. Returns the field's kind, which is a group
    /// when the field is delimited.
    fn check_field_declaration(
        &mut self,
        file: FileIndex,
        path: &[i32],
        field: &FieldDescriptorProto,
        kind: KindIndex,
        containing_map_entry: bool,
        features: Features,
    ) -> KindIndex {
        if field.label() == field_descriptor_proto::Label::Required {
            self.error(
                file,
                &join_path(path, &[tag::field::LABEL]),
                "required label is not allowed under editions; use the feature field_presence = \
                 LEGACY_REQUIRED instead",
            );
        }
        if field.r#type() == field_descriptor_proto::Type::Group {
            self.error(
                file,
                &join_path(path, &[tag::field::TYPE]),
                "group types are not allowed under editions; use the feature message_encoding = \
                 DELIMITED instead",
            );
        }
        if field
            .options
            .as_ref()
            .is_some_and(|o| o.value.packed.is_some())
        {
            self.error(
                file,
                &join_path(path, &[tag::field::OPTIONS, tag::field::options::PACKED]),
                "field option packed is not allowed under editions; use the feature \
                 repeated_field_encoding instead",
            );
        }

        match kind {
            KindIndex::Message(message)
                if features.message_encoding == MessageEncoding::Delimited
                    && !containing_map_entry
                    && !self.is_map_entry(message) =>
            {
                KindIndex::Group(message)
            }
            kind => kind,
        }
    }

    /// The checks protoc applies to the features set explicitly on a field.
    fn check_explicit_field_features(
        &mut self,
        file: FileIndex,
        path: &[i32],
        field: &FieldDescriptorProto,
        kind: KindIndex,
        is_extension: bool,
    ) {
        let Some(set) = field
            .options
            .as_ref()
            .and_then(|o| FeatureSetProto::from_options(&o.encoded, tag::features::FIELD))
        else {
            return;
        };

        let repeated = field.label() == field_descriptor_proto::Label::Repeated;
        if let Some(presence) = set.field_presence {
            if field.oneof_index.is_some() {
                self.feature_error(file, path, "oneof fields can't specify field presence");
            } else if repeated {
                self.feature_error(file, path, "repeated fields can't specify field presence");
            } else if is_extension && presence != 3 {
                self.feature_error(file, path, "extensions can't specify field presence");
            } else if kind.is_message() && presence == 2 {
                self.feature_error(file, path, "message fields can't specify implicit presence");
            }
        }
        if !repeated && set.repeated_field_encoding.is_some() {
            self.feature_error(
                file,
                path,
                "only repeated fields can specify repeated field encoding",
            );
        }
        if !kind.is_packable() && set.repeated_field_encoding == Some(1) {
            self.feature_error(
                file,
                path,
                "only repeated primitive fields can specify PACKED repeated field encoding",
            );
        }
        if set.utf8_validation.is_some() && !self.is_string_or_string_map(kind) {
            self.feature_error(file, path, "only string fields can specify utf8 validation");
        }
        if set.message_encoding.is_some()
            && (!kind.is_message() || self.is_map_field(kind, repeated))
        {
            self.feature_error(
                file,
                path,
                "only message fields can specify message encoding",
            );
        }
    }

    fn is_map_field(&self, kind: KindIndex, repeated: bool) -> bool {
        match kind {
            KindIndex::Message(message) => repeated && self.is_map_entry(message),
            _ => false,
        }
    }

    fn is_string_or_string_map(&self, kind: KindIndex) -> bool {
        match kind {
            KindIndex::String => true,
            KindIndex::Message(message) if self.is_map_entry(message) => self.pool.messages
                [message as usize]
                .fields
                .iter()
                .any(|f| matches!(f.kind, KindIndex::String)),
            _ => false,
        }
    }

    fn is_closed_enum(&self, kind: KindIndex) -> bool {
        match kind {
            KindIndex::Enum(enum_) => {
                self.pool.enums[enum_ as usize].features.enum_type == EnumType::Closed
            }
            _ => false,
        }
    }
}

impl Visitor for EditionsVisitor<'_> {
    fn visit_field(
        &mut self,
        path: &[i32],
        _: &str,
        file: FileIndex,
        message: MessageIndex,
        index: FieldIndex,
        field: &FieldDescriptorProto,
    ) {
        if !self.is_editions(file) {
            return;
        }

        let containing_map_entry = self.is_map_entry(message);
        let inner = &self.pool.messages[message as usize].fields[index as usize];
        let (features, kind, in_oneof) = (inner.features, inner.kind, inner.oneof.is_some());

        let kind =
            self.check_field_declaration(file, path, field, kind, containing_map_entry, features);

        let repeated = field.label() == field_descriptor_proto::Label::Repeated;
        let cardinality = if repeated {
            Cardinality::Repeated
        } else if features.field_presence == FieldPresence::LegacyRequired {
            Cardinality::Required
        } else {
            Cardinality::Optional
        };
        let supports_presence = !repeated
            && (kind.is_message()
                || in_oneof
                || features.field_presence != FieldPresence::Implicit);

        if !repeated && !supports_presence {
            if field.default_value.is_some() {
                self.error(
                    file,
                    &join_path(path, &[tag::field::DEFAULT_VALUE]),
                    "implicit presence fields can't specify defaults",
                );
            }
            if self.is_closed_enum(kind) {
                self.error(
                    file,
                    &join_path(path, &[tag::field::TYPE_NAME]),
                    "implicit presence enum fields must always be open",
                );
            }
        }

        // Map entries copy their map field's features to the key and value; protoc checks them
        // on the map field only.
        if !containing_map_entry {
            self.check_explicit_field_features(file, path, field, kind, false);
        }

        let inner = &mut self.pool.messages[message as usize].fields[index as usize];
        inner.kind = kind;
        inner.cardinality = cardinality;
        inner.supports_presence = supports_presence;
        inner.is_packed = repeated
            && kind.is_packable()
            && features.repeated_field_encoding == RepeatedFieldEncoding::Packed;
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
        if !self.is_editions(file) {
            return;
        }

        let inner = &self.pool.extensions[index as usize];
        let (features, kind) = (inner.features, inner.kind);

        let kind = self.check_field_declaration(file, path, extension, kind, false, features);

        let repeated = extension.label() == field_descriptor_proto::Label::Repeated;
        if features.field_presence == FieldPresence::LegacyRequired && !repeated {
            self.error(file, path, "extensions can't be required");
        }
        self.check_explicit_field_features(file, path, extension, kind, true);

        let inner = &mut self.pool.extensions[index as usize];
        inner.kind = kind;
        inner.is_packed = repeated
            && kind.is_packable()
            && features.repeated_field_encoding == RepeatedFieldEncoding::Packed;
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
        if self.is_editions(file)
            && self.pool.enums[index as usize].features.enum_type == EnumType::Open
            && enum_.value.first().is_some_and(|v| v.number() != 0)
        {
            self.error(
                file,
                &join_path(path, &[tag::enum_::VALUE, 0, tag::enum_value::NUMBER]),
                "the first value of an open enum must be 0",
            );
        }
    }
}

/// A label for a feature error at `path` (the `features` field of an options message): the
/// source location of the first feature set there, when the file has source info.
fn feature_label(
    files: &[crate::descriptor::FileDescriptorInner],
    file: FileIndex,
    path: &[i32],
) -> Label {
    let located = files[file as usize]
        .raw
        .source_code_info
        .as_ref()
        .and_then(|info| info.location.iter().find(|l| l.path.starts_with(path)))
        .map(|l| l.path.clone().into_boxed_slice());
    Label::new(
        files,
        "found here",
        file,
        located.unwrap_or_else(|| path.into()),
    )
}
