# Boolean operators

An expression form. Part of the [SQL reference](README.md).

**Syntax:** `<left> and <right>` | `<left> or <right>` | `not <operand>`

`and`, `or`, and `not` combine Bool-valued sub-expressions, and are
case-insensitive like the other keywords. Both operands of `and` and
`or`, and the single operand of `not`, must be of type Bool; a non-Bool
operand is rejected (so `not active` is fine but `not name` is not).

`and` and `or` are left-associative; `not` is a prefix operator and
stacks (`not not active` parses). For how they bind relative to
comparisons and to each other, see
[precedence](precedence.md).

`and` and `or` **short-circuit**: the right operand is evaluated only
when the left doesn't already decide the result — `false and …` skips
the right, as does `true or …`. With today's expression language this
isn't observable (no sub-expression can fail or have a side effect, so
evaluating the right operand never changes the outcome), but it is the
defined semantics, and it becomes visible once fallible expressions
such as arithmetic arrive. The same evaluator backs the relational-
algebra surface, so the behaviour is identical there.

```
sql> SELECT id FROM users WHERE not active
 id 
----
  2 
  5 
(2 rows)
```
