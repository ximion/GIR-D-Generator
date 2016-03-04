
default_target: all
.PHONY : default_target

all: build glibwrap

build:
	dub build
.PHONY : build

glibwrap: build
	./build/gir-d-generator -i ./glib-wrap -o ./build/wrapped
.PHONY : build

install: build glibwrap
	echo "TODO"

clean:
	rm -rf ./build
