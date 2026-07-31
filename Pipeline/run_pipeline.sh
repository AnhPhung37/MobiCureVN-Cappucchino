#!/usr/bin/env bash
# Full RAG ingestion pipeline: PDF → vectorstore.db
#
# Stages (run in order unless --stages is specified):
#   parse   raw_pdfs/         → parsed_markdowns/
#   clean   parsed_markdowns/ → cleaned_markdowns/
#   chunk   cleaned_markdowns/ → neural_chunks/ and/or semantic_chunks/
#   enrich  {chunker}_chunks/ → enriched_chunks/
#   index   enriched_chunks/  → vectorstore.db
#
# Usage:
#   ./run_pipeline.sh
#   ./run_pipeline.sh --chunker semantic
#   ./run_pipeline.sh --chunker both
#   ./run_pipeline.sh --stages parse clean
#   ./run_pipeline.sh --force
#   ./run_pipeline.sh --force --stages chunk index

set -euo pipefail
cd "$(dirname "$0")"

FORCE=""
CHUNKER="neural"
ALL_STAGES=(parse clean chunk enrich index)
STAGES=("${ALL_STAGES[@]}")

usage() {
    echo "Usage: $0 [--force] [--chunker neural|semantic|both] [--stages STAGE ...]"
    echo "Stages: ${ALL_STAGES[*]}"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)   FORCE="--force"; shift ;;
        --chunker) CHUNKER="$2"; shift 2 ;;
        --stages)
            shift
            STAGES=()
            while [[ $# -gt 0 && "$1" != --* ]]; do
                STAGES+=("$1"); shift
            done
            ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

echo "Pipeline: stages=${STAGES[*]}  chunker=${CHUNKER}  force=${FORCE:-none}"

for stage in "${STAGES[@]}"; do
    case $stage in
        parse)
            echo -e "\n=== Stage 1: Parse PDFs ==="
            python ingestion/parse.py $FORCE
            ;;
        clean)
            echo -e "\n=== Stage 2: Clean Markdown ==="
            python ingestion/clean.py $FORCE
            ;;
        chunk)
            echo -e "\n=== Stage 3: Chunk ==="
            python ingestion/chunk.py --chunker "$CHUNKER" $FORCE
            ;;
        enrich)
            # When --chunker both, enrich from neural (the primary pipeline)
            ENRICH_FROM=$([[ "$CHUNKER" == "semantic" ]] && echo "semantic" || echo "neural")
            echo -e "\n=== Stage 4: Enrich Chunks (from data/${ENRICH_FROM}_chunks/) ==="
            python ingestion/enrich_chunks.py --chunker "$ENRICH_FROM" $FORCE
            ;;
        index)
            echo -e "\n=== Stage 5: Build Vector Index ==="
            python ingestion/build_index.py $FORCE
            ;;
        *)
            echo "Unknown stage: $stage"
            usage
            ;;
    esac
done

echo -e "\nPipeline complete."
