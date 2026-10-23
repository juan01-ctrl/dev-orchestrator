#!/bin/sh
set -eu
bin/dev_orchestrator eval 'DevOrchestrator.Release.migrate()'
exec bin/dev_orchestrator start
