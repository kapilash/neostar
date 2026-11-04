(identifier) @variable
(qualified_identifier) @variable
(constructor_identifier) @constructor

[(line_comment) (block_comment)] @comment
(string) @string
(escape_sequence) @string.escape
(character) @character
(integer) @number
(real) @number.float
[(boolean) (unit) (source_macro)] @constant.builtin
(builtin_constant) @function.builtin
(wildcard) @variable.builtin
(universe) @constant

[(attribute) (binder_attribute)] @attribute
(qualifier) @keyword.modifier
[
 "module" "open" "include" "friend" "let" "and" "rec" "val" "assume"
 "type" "class" "instance" "exception" "of" "effect" "new_effect" "sub_effect"
 "with" "fun" "λ" "function" "if" "then" "else" "match" "try" "when"
 "in" "as" "begin" "end" "forall" "exists" "requires" "ensures" "returns"
 "returns$" "decreases" "assert" "by" "synth" "calc" "introduce" "eliminate"
 "quote"
] @keyword
[
 "#show-options" "#pop-options" "#restart-solver" "#print-effects-graph"
 "#set-options" "#reset-options" "#push-options" "#check" "#eval"
 "#lang-" "%splice" "%splice_t"
] @keyword.directive
(extension_language) @label

(module_declaration name: (_) @module)
(module_alias name: (_) @module value: (_) @module)
[(open_declaration name: (_) @module)
 (include_declaration name: (_) @module)
 (friend_declaration name: (_) @module)
 (module_open_expression name: (_) @module)]
(type_definition name: (_) @type.definition)
(constructor_declaration name: (_) @constructor)
[(effect_declaration name: (_) @type.definition)
 (effect_definition name: (_) @type.definition)
 (effect_abbreviation name: (_) @type.definition)]

[(let_declaration name: (identifier) @variable.definition)
 (let_expression name: (identifier) @variable.definition)
 (bind_expression name: (identifier) @variable.definition)
 (variable_pattern name: (identifier) @variable.definition)]
(binder name: (identifier) @variable.parameter)
(constraint name: (identifier) @variable.parameter)
(refinement_type name: (identifier) @variable.parameter)
[(let_declaration parameters: (variable_pattern name: (identifier) @variable.parameter))
 (let_expression parameters: (variable_pattern name: (identifier) @variable.parameter))
 (lambda_expression parameters: (variable_pattern name: (identifier) @variable.parameter))
 (let_declaration parameters: (ascribed_pattern pattern: (variable_pattern name: (identifier) @variable.parameter)))
 (let_expression parameters: (ascribed_pattern pattern: (variable_pattern name: (identifier) @variable.parameter)))
 (lambda_expression parameters: (ascribed_pattern pattern: (variable_pattern name: (identifier) @variable.parameter)))]
(let_declaration name: (_) @function . parameters: (_))
(val_declaration name: (_) @function)
(application_expression function: (_) @function.call)

[(binder type: (_) @type)
 (val_declaration type: (_) @type)
 (record_field_declaration type: (_) @type)
 (ascription_expression type: (_) @type)]
[(record_field field: (_) @property)
 (record_pattern_field field: (_) @property)
 (record_field_declaration name: (_) @property)
 (projection_expression field: (_) @property)
 (projector_expression field: (_) @property)]

(operator) @operator
(operator_identifier) @operator
[(binary_expression operator: _ @operator)
 (unary_expression operator: _ @operator)
 (sequence_expression operator: _ @operator)
 (quotation_expression operator: _ @operator)]
["=" "->" "~>" "<--" "<-" ":" "<:" "$:" "#" "$" "+" "-" "~" "::" ":=" "==>" "<==>" "/\\" "\\/" "<@" "?" "?."] @operator
["(" ")" "[" "]" "{" "}" "(|" "|)" "{|" "|}"
 ".(" ".[" ".(|" ".[|" "|]" "seq![" "%[" "!{"] @punctuation.bracket
["," ";" "." "|" "```"] @punctuation.delimiter
