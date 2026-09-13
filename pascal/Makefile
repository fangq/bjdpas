# bjdata.pas - build the regression suite and the bjd2json tool
#
#   make test    build and run the regression suite
#   make tools   build tools/bjd2json
#   make bench   time the decoder and the encoder (BENCHFILES=... to pick files)
#   make cross   run the interoperability check against the python bjdata module
#   make clean   remove the build output

FPC      ?= fpc
FPCFLAGS ?= -Mobjfpc -Sh -O2 -vw
OUT      ?= build
PYTHON   ?= python3

.PHONY: all test tools bench cross clean

all: test tools

$(OUT):
	@mkdir -p $(OUT)

$(OUT)/bjdtest: bjdata.pas test/bjdtest.lpr | $(OUT)
	$(FPC) $(FPCFLAGS) -Fu. -FU$(OUT) -FE$(OUT) -o$(OUT)/bjdtest test/bjdtest.lpr

$(OUT)/bjd2json: bjdata.pas tools/bjd2json.lpr | $(OUT)
	$(FPC) $(FPCFLAGS) -Fu. -FU$(OUT) -FE$(OUT) -o$(OUT)/bjd2json tools/bjd2json.lpr

$(OUT)/bench: bjdata.pas test/bench.lpr | $(OUT)
	$(FPC) $(FPCFLAGS) -Fu. -FU$(OUT) -FE$(OUT) -o$(OUT)/bench test/bench.lpr

test: $(OUT)/bjdtest
	$(OUT)/bjdtest

tools: $(OUT)/bjd2json

bench: $(OUT)/bench
	$(OUT)/bench -n 5 $(BENCHFILES)

cross: $(OUT)/bjd2json
	$(PYTHON) test/crosscheck.py $(OUT)/bjd2json

clean:
	rm -rf $(OUT)
