//! The repo's real `ui_example.txt` must always compile clean; hot reload
//! prints warnings at runtime, but nothing should ship tripping them.

use arena::Arena;

#[test]
fn repo_ui_example_compiles_clean() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui_example.txt");
    let source = std::fs::read_to_string(path).unwrap();
    let arena = Arena::new();
    let module = ui::ir::compile(&arena, &source);
    assert!(module.errors.is_empty(), "{:?}", module.errors);
    assert!(module.warnings.is_empty(), "{:?}", module.warnings);
    assert_ne!(module.roots(), 0);
}
