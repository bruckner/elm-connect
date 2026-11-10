- A generated binary decoder sets a field on one line,
  `(\v -> { value | text = v })`, where it stacked the record update
  over five lines before; any record update of one field whose value
  fits on a line prints on one line.
