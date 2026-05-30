# Comparisons

An expression form. Part of the [SQL reference](README.md).

**Syntax:** `<left> <op> <right>` where `<op>` is one of `=`, `<>`, `!=`,
`<`, `<=`, `>`, `>=`

Compares two sub-expressions and produces a Bool. The two sides' types
must agree:

- `=`, `<>`, and `!=` accept any matching type (Int64, String, or Bool).
  `<>` and `!=` are two spellings of the same not-equal operator.
- The four ordering operators (`<`, `<=`, `>`, `>=`) accept Int64 or
  String only; comparing Bool with an ordering operator is rejected.

String comparison is lexicographic by byte. Comparisons are
non-associative: a chain like `a < b < c` does not parse.

```
sql> SELECT * FROM orders WHERE amount >= 5
 id | user_id | description | amount 
----+---------+-------------+--------
  1 |       1 | Coffee      |      5 
  4 |       3 | Sandwich    |      8 
  5 |       3 | Cake        |      6 
(3 rows)
```

Strings order lexicographically:

```
sql> SELECT name FROM users WHERE name >= 'Carol'
 name  
-------
 Carol 
 Dave  
 Eve   
(3 rows)
```
