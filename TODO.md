# Jus
Active varibles that bind to vanilla Julia code -- no need to implement the observer pattern

- [ ] fix deleting people in sample app
- [ ] implement `delete id` that deletes a var and all its children
- [ ] rename disableSelection to disableUpdates
- [ ] allow disabling variable observation
- [ ] naked objects for types that have no vewidef
  - [ ] make the server replace 'viewdef=auto' with a computed viewdef
  - [ ] use methodswith to find methods that take a VarCmd{:set} and the datatype:
        https://docs.julialang.org/en/v1/stdlib/InteractiveUtils/#InteractiveUtils.methodswith
- [ ] floating editor mode (1 or 2 additional views for PersonApp)
- [X] make a separate output task for each connection so that background code can update the front end
- [X] make adjustIndex work
- [X] make a `present` Julia function that opens a browser, plus a cmd line option to invoke it
- [X] merge result and update into one object (pass result to finish_command)
  - process in result, update order but only return from promise after both
- [X] switch to fast components (it has a tree view):
      https://www.fast.design/docs/components/getting-started/
- [X] use [material web components for widgets](https://github.com/material-components/material-web)
- [X] take out mwc- references from generic codebase
  - [X] support extension so mwc- can work and put mwc extension in samples

Parts

- [X] refreshing
  - [ ] parents can transform variable values
    - [X] implement
    - [ ] test
- [X] setting variables
- [X] observing variables
- [X] routing commands
  - [X] parents can alter commands
  - [X] current values can alter commands
- [X] metadata
  - [X] path
    - [X] composed of fields and functions: "a b() c d"
    - [X] each item is called with the previous one
    - functions are allowed to contain dots (for module qualifiers)
    - [X] for a setter, the final item is
      - [X] assigned to the value if it is a symbol
      - [X] called with (data, value) if it is a function
    - [X] actions
      - access=action
      - like a setter but called with no args
      - last element must be a function
      - function will be called with (data), like a getter (not (data, value))
