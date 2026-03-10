; tags.scm - Dart symbol tagging queries

; Classes
(class_declaration
  name: (identifier) @name) @definition.class

; Mixins
(mixin_declaration
  (identifier) @name) @definition.class

; Extensions
(extension_declaration
  name: (identifier) @name) @definition.class

; Extension types
(extension_type_declaration
  name: (extension_type_name
    (identifier) @name)) @definition.class

; Enums
(enum_declaration
  name: (identifier) @name) @definition.class

; Top-level functions
(source_file
  (function_signature
    name: (identifier) @name)
  (function_body)) @definition.function

; Top-level getters
(source_file
  (getter_signature
    name: (identifier) @name)
  (function_body)) @definition.function

; Top-level setters
(source_file
  (setter_signature
    name: (identifier) @name)
  (function_body)) @definition.function

; Methods
(method_signature
  (function_signature
    name: (identifier) @name)) @definition.method

; Getters (as methods)
(method_signature
  (getter_signature
    name: (identifier) @name)) @definition.method

; Setters (as methods)
(method_signature
  (setter_signature
    name: (identifier) @name)) @definition.method

; Operator methods
(method_signature
  (operator_signature)) @definition.method

; Constructors
(constructor_signature
  name: (identifier) @name) @definition.method

; Const constructors
(constant_constructor_signature
  (identifier) @name) @definition.method

; Factory constructors
(factory_constructor_signature
  (identifier) @name) @definition.method

; Redirecting factory constructors
(redirecting_factory_constructor_signature
  (identifier) @name) @definition.method

; Typedefs
(type_alias
  (type_identifier) @name) @definition.type

; Enum constants
(enum_constant
  name: (identifier) @name) @definition.constant
