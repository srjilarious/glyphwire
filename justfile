alias t := test
alias b := build
# alias bwin := build_win
# alias d := docs

# docs :
# 	zig build docs

# Repeatable Linux build: verify the pinned Zig, prime the cache, then `zig build {{ARGS}}`
bootstrap *ARGS:
	./scripts/bootstrap-linux.sh {{ARGS}}

test *OPTS:
	zig build tests -- {{OPTS}}

build EX *OPTS:
	zig build {{EX}} {{OPTS}}

# build_win EX *OPTS:
# 	zig build -Dtarget=x86_64-windows {{EX}} {{OPTS}}
