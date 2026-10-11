//! The two googleapis files that declare `google.api.http`, embedded so a
//! proto that imports `google/api/annotations.proto` compiles without the
//! googleapis repository on the include path.
//!
//! The files are `google/api/http.proto` and `google/api/annotations.proto`
//! from googleapis at commit `525d4c82dc1dd2fa3884198a8006a7bf5b48ac9d`,
//! unmodified, under the Apache License 2.0 (`THIRD_PARTY.md` at the
//! repository root). Their one other import, `google/protobuf/descriptor.proto`,
//! protox bundles.
//!
//! [`resolver`] serves them to protox after the user's include paths, so a
//! copy on the include path wins. The protoc plugin needs none of this:
//! protoc resolves imports itself and sends every file in the request.

use protox::Error;
use protox::file::{ChainFileResolver, File, FileResolver, GoogleFileResolver};
use std::path::PathBuf;

/// The embedded files, by import name.
pub const FILES: [(&str, &str); 2] = [
    (
        "google/api/http.proto",
        include_str!("../googleapis/google/api/http.proto"),
    ),
    (
        "google/api/annotations.proto",
        include_str!("../googleapis/google/api/annotations.proto"),
    ),
];

/// A protox resolver for the embedded files alone.
#[derive(Clone, Copy, Debug, Default)]
pub struct GoogleApisResolver;

impl FileResolver for GoogleApisResolver {
    fn open_file(&self, name: &str) -> Result<File, Error> {
        match FILES.iter().find(|(file, _)| *file == name) {
            Some((_, source)) => File::from_source(name, source),
            None => Err(Error::file_not_found(name)),
        }
    }
}

/// The resolver both entry points compile with: each of `includes` in
/// order, then protox's bundled `google/protobuf` files, then the embedded
/// googleapis files.
pub fn resolver(includes: impl IntoIterator<Item = PathBuf>) -> ChainFileResolver {
    let mut resolver = ChainFileResolver::new();
    for include in includes {
        resolver.add(protox::file::IncludeFileResolver::new(include));
    }
    resolver.add(GoogleFileResolver::new());
    resolver.add(GoogleApisResolver);
    resolver
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_files_compile_and_declare_the_extension() {
        let mut compiler = protox::Compiler::with_file_resolver(resolver([]));
        compiler
            .open_file("google/api/annotations.proto")
            .expect("compiles");
        let pool = compiler.descriptor_pool();
        let extension = pool
            .get_extension_by_name("google.api.http")
            .expect("declared");
        assert_eq!(extension.number(), 72_295_728);
    }

    #[test]
    fn an_include_path_wins() {
        let dir = std::env::temp_dir().join("elm-connect-googleapis-wins");
        let api = dir.join("google/api");
        std::fs::create_dir_all(&api).expect("create");
        std::fs::write(
            api.join("http.proto"),
            "syntax = \"proto3\";\npackage google.api;\nmessage HttpRule { string get = 2; }\n",
        )
        .expect("write");
        let resolver = resolver([dir]);
        let file = resolver.open_file("google/api/http.proto").expect("found");
        assert!(file.source().is_some_and(|s| s.len() < 100));
    }
}
