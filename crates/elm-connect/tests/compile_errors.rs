use std::path::PathBuf;

use miette::{GraphicalReportHandler, GraphicalTheme};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn render(report: &miette::Report) -> String {
    let handler =
        GraphicalReportHandler::new_themed(GraphicalTheme::unicode_nocolor()).with_width(80);
    let mut out = String::new();
    handler
        .render_report(&mut out, report.as_ref())
        .expect("rendering a report into a String cannot fail");
    out
}

#[test]
fn syntax_error_renders_with_file_and_line() {
    let report = elm_connect::compile(&[PathBuf::from("broken.proto")], &[fixtures()])
        .expect_err("broken.proto has a missing semicolon");
    let rendered = render(&report);

    assert!(rendered.contains("broken.proto:7:"), "{rendered}");
    assert!(rendered.contains("string body = 2;"), "{rendered}");
}
