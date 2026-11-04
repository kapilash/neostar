; inherits: fstar

[
 "mut" "invariant" "predicate" "while" "fn" "each" "rewrite"
 "fold" "opens" "ghost" "atomic" "unobservable" "divergent"
 "norewrite" "goto" "label" "return" "defer"
] @keyword
[(pulse_show_proof_state_statement) (pulse_break_statement) (pulse_continue_statement)] @keyword

[(pulse_function_declaration name: (_) @function)
 (pulse_function_definition name: (_) @function)
 (pulse_local_function_statement name: (_) @function)
 (pulse_predicate_declaration name: (_) @function)]
(pulse_contract kind: _ @keyword)
(pulse_loop_clause kind: _ @keyword)
(pulse_contract name: (identifier) @variable.parameter)
(pulse_let_statement pattern: (variable_pattern name: (identifier) @variable.definition))
[(pulse_label_statement name: (identifier) @label)
 (pulse_goto_statement name: (identifier) @label)]
(pulse_assignment_statement operator: _ @operator)
["[|" "|]"] @punctuation.bracket
