# Used by "mix format"
[
  import_deps: [:breeze],
  plugins: [Breeze.HTMLFormatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,examples}/**/*.{ex,exs}"]
]
