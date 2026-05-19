# Sub-library dependencies

Internal dependencies between the sub-libraries under `lib/`. External
packages (`lmdb`, `unix`, `angstrom`) are omitted.

`core` is depended on by every other sub-library, so the diagram shows
it as a foundation layer with a single arrow from the upper layer
rather than repeating the edge seven times.

```mermaid
graph TD
  subgraph upper [ ]
    storage[storage]
    plan[plan]
    ddl[ddl]
    surface_ra[surface_ra]
    execution[execution]
    frontend[frontend]

    surface_ra --> plan
    surface_ra --> ddl

    execution --> storage
    execution --> plan
    execution --> ddl

    frontend --> storage
    frontend --> plan
    frontend --> ddl
    frontend --> surface_ra
    frontend --> execution
  end

  subgraph foundation [ ]
    core[core]
  end

  upper --> foundation
```
