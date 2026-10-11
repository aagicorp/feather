# Tree-sitter queries

One folder per grammar Feather ships (see `TreeSitterLanguage` in Sources/Feather/Language/TreeSitterLanguage.swift).
`highlights.scm` is the grammar's own highlight query, with the TypeScript and TSX ones followed by the JavaScript
queries they build on, in the order the grammar's `tree-sitter.json` lists them (an earlier pattern wins for a node).
`injections.scm`, where present, says which parts are written in another language (HTML's `<script>`, tagged
template literals). All come from MIT-licensed grammar repositories pinned in Package.swift; copy them again after
bumping a grammar. build.sh copies this folder into Feather.app.
