# Precedence and associativity

Expression binding rules. Part of the
[query-language reference](README.md).

From tightest to loosest binding:

| Level | Construct                            | Associativity     |
| ----- | ------------------------------------ | ----------------- |
| 1     | Atoms (literals, column refs, `(…)`) | n/a               |
| 2     | Comparisons (`=`, `<>`, `<`, `<=`, `>`, `>=`) | non-associative |
| 3     | `not <operand>`                      | prefix unary; stacks |
| 4     | `<left> and <right>`                 | left-associative  |
| 5     | `<left> or <right>`                  | left-associative  |

So `a or b and not c = 1` parses as `a or (b and (not (c = 1)))`.
When that's not what you want, parenthesise.
