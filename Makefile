ASM = acme
C64U = 192.168.1.103
SRC = c64claude.asm
PRG = c64claude.prg

all: $(PRG)

$(PRG): $(SRC)
	$(ASM) -f cbm -o $(PRG) $(SRC)

deploy: $(PRG)
	@echo "Deploying to C64U at $(C64U)..."
	curl -s -X POST http://$(C64U)/v1/runners:run_prg \
	  --data-binary @$(PRG) \
	  -H "Content-Type: application/octet-stream"
	@echo "\nDeployed!"

bridge:
	python3 bridge.py

run: deploy
	@echo "Waiting for C64 to initialize..."
	@sleep 2
	python3 bridge.py

clean:
	rm -f $(PRG)

.PHONY: deploy bridge run clean
