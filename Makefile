all: jus.so samples

jus.so:
	julia -q -e 'using PackageCompiler, Pkg; Pkg.activate("."); using HTTP, JSON3, Match, Revise, DefaultApplication, Generators; create_sysimage(["HTTP", "JSON3", "Match", "Revise", "DefaultApplication", "Generators"]; sysimage_path="jus.so")'

samples: samples/output/widgets.js

run: FRC
	./jus ROOT -s localhost:7777 -e 'include("../samples/src/example1.jl")' -i samples/html -b PersonApp

FRC:
