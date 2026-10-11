; Assembled from tree-sitter-html/queries/highlights.scm (MIT licensed grammar repositories). Earlier patterns win.

; ---- tree-sitter-html/queries/highlights.scm
(tag_name) @tag
(erroneous_end_tag_name) @tag.error
(doctype) @constant
(attribute_name) @attribute
(attribute_value) @string
(comment) @comment

[
  "<"
  ">"
  "</"
  "/>"
] @punctuation.bracket
