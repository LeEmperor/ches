module.exports = grammar({
  name: 'gas',

  extras: $ => [$._inline_space, $.comment],

  rules: {
    source_file: $ => seq(
      repeat(choice(
        $._eol,
        seq(optional($.label), $._statement, $._eol),
        seq($.label, $._eol)
      )),
      optional($.label),
      optional($._statement)
    ),

    _statement: $ => choice(
      $.directive, 
      $.instruction, 
      $.assignment
    ),

    label: $ => /([a-zA-Z_\.\$][a-zA-Z0-9_\.\$]*|[0-9]+):/,

    local_label_reference: $ => /[0-9]+[bf]/,

    directive: $ => choice(
      seq(
        $.directive_name,
        optional(seq(
          $._inline_space,
          $._directive_arg,
          repeat(seq(',', optional($._directive_arg)))
        ))
      ),
      // Debug directives use whitespace-separated atoms, not arithmetic lists.
      // Keep this separate so `.long 1f - 0f` remains one expression, and
      // `.loc ... view -0` keeps the signed number as a separate argument.
      seq(
        alias(choice('.file', '.loc'), $.directive_name),
        repeat(seq($._inline_space, choice($.number, $.string, $.symbol))),
        optional($._inline_space)
      )
    ),

    directive_name: $ => /\.[a-zA-Z_\.\$][a-zA-Z0-9_\.\$]*/,

    _directive_arg: $ => choice(
      $.type, 
      $.char, 
      $.string, 
      $.expression
    ),

    type: $ => seq('@', $._identifier),

    assignment: $ => seq(
      $.symbol,
      repeat(choice($._inline_space, $.comment)),
      '=',
      $.expression
    ),

    expression: $ => choice(
      prec.left(seq($.expression, choice('-', '+', '*', '/', '='), $.expression)),
      $._sub_expression
    ),

    _paren_expression: $ => seq('(', $.expression, ')'),

    _sub_expression: $ => choice(
      $.symbol,
      $.number,
      $.local_label_reference,
      $._paren_expression
    ),

    instruction: $ => seq(
      optional(seq($.instruction_prefix, $._inline_space)),
      alias($.symbol, $.instruction_name),
      optional(seq(
        $._inline_space,
        optional('*'),
        $._operand,
        repeat(seq(',', $._operand))
      ))
    ),

    instruction_prefix: $ => choice(
      ci('data16'), ci('addr16'), ci('data32'), ci('addr32'),
      ci('lock'),
      ci('wait'),
      ci('rep'), ci('repe'), ci('repne'),
      /[rR][eE][xX](64)?[xX]?[yY]?[zZ]?/
    ),

    _operand: $ => choice(
      $.register, 
      $._operand_expression,
      $.char, 
      $.string, 
      $.constant, 
      $._displacement_expression
    ),

     // symbols in operands cannot start with $
    _operand_symbol: $ => seq(
      alias(/[a-zA-Z_\.][a-zA-Z0-9_\.\$]*/, $.symbol),
      optional($.operand_modifier)
    ),

    operand_modifier: $ => /@[a-zA-Z0-9]+/,

    _displacement_expression: $ => choice(
      seq(
        optional(seq($.register, ':')),
        optional(seq($._displacement_expression_offset)),
        '(',
        choice(
          $.register,
          seq(',', $._displacement_expression_offset),
          seq(
            optional(choice(',', seq($.register, ','))),
            $.register,
            optional(seq(',', $._displacement_expression_offset))
          )
        ),
        ')'
      ),
      seq(
        seq($.register, ':'),
        seq($._displacement_expression_offset)
      )
    ),

    _operand_expression: $ => choice(
      prec.left(seq($._operand_expression, choice('-', '+', '*', '/'), $._operand_expression)),
      $.number,
      $.local_label_reference,
      $._operand_symbol
    ),

    _displacement_expression_offset: $ => prec(1, $._operand_expression),

    constant: $ => seq('$', choice($.expression, $.string, $.char)),
    
    char: $ => seq('\'', choice($._character_escapes, /[^\\']/), optional('\'')),

    _character_escapes: $ => /\\b|\\f|\\n|\\r|\\t|\\\\|\\"|\\'/,

    string: $ => /"(\\[0-9]{3}|\\x[0-9a-fA-F]{2}|\\b|\\f|\\n|\\r|\\t|\\\\|\\"|[^\n\r\\"])*"/,

    number: $ => choice($._integer, $._float),

    _integer: $ => /-?(0[bB][01]*|0[0-7]*|[1-9][0-9]*|0[xX][0-9a-fA-F]+)/,

    _float: $ => /0[a-zA-Z][+\-]?[0-9]*\.?[0-9]*([eE][+\-]?[0-9]+)?/,

    symbol: $ => $._identifier,

    _identifier: $ => /[a-zA-Z_\.\$][a-zA-Z0-9_\.\$]*/,

    register: $ => /%[a-zA-Z][a-zA-Z0-9]*/,

    comment: $ => choice(
      /#[^\n]*/,
      seq('/*', repeat(choice(/./, $._eol)), '*/')
    ),

    _inline_space: $ => /[\t ]+/,

    _eol: $ => /\r\n|\n\r|\n|\r|;/
  }
});

/** Make case insensitive regex. */
function ci(str) {
  const lower = str.toLowerCase();
  const upper = str.toUpperCase();
  let regex = "";
  for (let i = 0; i < str.length; i++)
    if (lower[i] == upper[i])
      regex += str[i];
    else
      regex += `[${lower[i]}${upper[i]}]`;
  return RegExp(regex);
}
