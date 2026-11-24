# Oracle AI Database 26ai SQL Doom renderer -- common commands.
PY      ?= .venv/bin/python
COMPOSE := docker compose -f oracle/docker-compose.yml
R       ?= render_optimized.sql
TIC     ?= 300

.PHONY: fetch-wad fetch-shareware-wad fetch-reference fetch-sources venv db-up db-down init test test-full render anim bench bench-baseline compare reference env setup shareware freedoom play play-single-session server player join web client-check load-wad

fetch-wad:       ## download Freedoom 0.13.0 freedoom1.wad (checksum-pinned) into oracle/wad/
	$(PY) oracle/client/fetch_data.py wad

fetch-shareware-wad: ## download the Doom 1.9 shareware doom1.wad (Debian package, checksum-pinned)
	$(PY) oracle/client/fetch_data.py shareware

fetch-reference: ## download the extended CedarDB ground truth (flows, scenarios, deathmatches; ~400 MB)
	$(PY) oracle/client/fetch_data.py reference

fetch-sources:   ## clone the three reference SQL Doom implementations into reference/ (pinned commits)
	$(PY) oracle/client/fetch_data.py sources

venv:            ## python env for the client / tools
	python3 -m venv .venv && .venv/bin/pip install -q oracledb numpy pillow pyarrow psycopg2-binary pygame-ce websockets

db-up:           ## start Oracle Free (gvenzl/oracle-free:full) and wait until healthy
	$(COMPOSE) up -d oracle
	until [ "$$(docker inspect -f '{{.State.Health.Status}}' sqldoom-oracle)" = healthy ]; do sleep 5; done

db-down:
	$(COMPOSE) down

setup: init      ## everything, once: init + the game, flow, screens + the deathmatch server, accounts broker, sound, music
	$(PY) oracle/client/setup_game.py
	$(PY) oracle/client/api_install.py --admin

init: fetch-wad  ## schema, WAD, recorded state, precompute, baseline support
	$(PY) oracle/client/setup_db.py

test:            ## correctness vs CedarDB ground truth (120 frames)
	$(PY) oracle/tests/run_correctness.py $(R) --tics 1-1200 --step 10

test-full:       ## all 1,200 frames
	$(PY) oracle/tests/run_correctness.py $(R) --tics 1-1200 --step 1

render:          ## one frame to PNG
	$(PY) oracle/client/render.py --renderer $(R) --tic $(TIC) --out frame_$(TIC).png

anim:            ## tics 1..350 as an animated GIF
	$(PY) oracle/client/render.py --renderer $(R) --tics 1-350 --out run.gif --scale 1

bench:           ## benchmark modes A+B over the 1,200-tic run (120 warm-up)
	$(PY) oracle/benchmark/bench.py $(R)

bench-baseline:  ## baseline is ~5 s/frame: sample every 10th tic
	$(PY) oracle/benchmark/bench.py render_baseline.sql --tics 1-1200 --step 10 --warmup 3 --label render_baseline

compare:         ## baseline vs optimized on 24 tics: exactness, agreement, latency
	$(PY) oracle/benchmark/compare.py render_baseline.sql render_optimized.sql --tics 1-1200 --step 50

reference: fetch-sources  ## (optional) regenerate ground truth with the CedarDB reference renderer
	$(COMPOSE) --profile reference up -d cedar
	cd reference/sqldoom && ../../$(PY) wad_loader.py ../../oracle/wad/freedoom1.wad E1M1 E1M2 E1M3 \
	  --dsn postgresql://postgres:postgres_doom_reference_pw@localhost:55433/postgres
	cd oracle/tests && ../../$(PY) record_reference.py \
	  --dsn postgresql://postgres:postgres_doom_reference_pw@localhost:55433/postgres --out ../reference_data/e1m1

env:             ## record image digest / version / parameters
	$(PY) oracle/benchmark/env_probe.py > oracle/analysis/environment.json

WAD ?= oracle/wad/freedoom1.wad
load-wad:        ## replace the game data with another IWAD, all its maps: make load-wad WAD=oracle/wad/doom1.wad (default: Freedoom)
	@test -f "$(WAD)" || { echo "no WAD at $(WAD)"; exit 1; }
	$(PY) oracle/client/setup_db.py --wad "$(WAD)"
	$(PY) oracle/client/setup_game.py
	DOOM_WAD="$(WAD)" $(PY) oracle/client/api_install.py
	@echo "loaded $(WAD). Tests and benchmarks need Freedoom: 'make freedoom' switches back."

shareware: fetch-shareware-wad  ## switch the game to Doom 1.9 shareware (episode 1, ~5 min)
	$(MAKE) load-wad WAD=oracle/wad/doom1.wad

freedoom: fetch-wad  ## switch the game back to Freedoom (needed by the tests and benchmarks)
	$(MAKE) load-wad WAD=oracle/wad/freedoom1.wad

play:            ## single player: title screen, menus, the whole game (pygame window; split rendering on 2+ DB CPUs)
	$(PY) oracle/client/doom_client.py

play-single-session: ## single player, each frame on one render session
	$(PY) oracle/client/doom_client.py --no-split

web:             ## the browser client + bridge on http://127.0.0.1:8080/ (needs a referee and accounts)
	$(PY) oracle/client/doom_web.py

client-check:    ## phase 6: the desktop client headless vs CedarDB, the UI flow smoke
	$(PY) oracle/tests/client_run_check.py --skip-cedar
	$(PY) oracle/tests/client_ui_smoke.py

MAP_ID ?= 1
SKILL  ?= 2
server:          ## deathmatch referee (the server): make server MAP_ID=1 SKILL=2; Ctrl-C stops it
	MAP_ID=$(MAP_ID) SKILL=$(SKILL) $(PY) oracle/client/referee.py

player:          ## create (or reset) a deathmatch account: make player NAME=alice (prints the password once)
	@test -n "$(NAME)" || { echo "usage: make player NAME=alice"; exit 1; }
	$(PY) oracle/client/accounts.py player $(NAME)

join:            ## join the running match: make join NAME=alice PASSWORD=... (or DOOM_PLAYER_PASSWORD)
	@test -n "$(NAME)" || { echo "usage: make join NAME=alice PASSWORD=..."; exit 1; }
	$(PY) oracle/client/doom_client.py --join $(NAME) $(if $(PASSWORD),--password '$(PASSWORD)',)
