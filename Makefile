.PHONY: test
test:
	julia --color=yes test/runtests.jl

.PHONY: example
example:
	julia --color=yes example/showcase.jl
