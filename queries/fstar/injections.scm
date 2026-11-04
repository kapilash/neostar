((syntax_extension
  language: (extension_language) @_language
  body: (extension_content) @injection.content)
 (#eq? @_language "pulse")
 (#set! injection.language "pulse"))

((language_extension
  language: (extension_language) @_language
  body: (language_content) @injection.content)
 (#eq? @_language "pulse")
 (#set! injection.language "pulse"))

((language_extension
  language: (extension_language) @_language
  body: (language_content) @injection.content)
 (#eq? @_language "fstar")
 (#set! injection.language "fstar"))
