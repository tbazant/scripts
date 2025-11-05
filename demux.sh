#!/bin/bash
#
# This script demuxes audio files into stem streams using a Docker container.
# It can process a single file or a playlist of files.
# The output structure is based on the parent directory of the input files.
# For example, an input file 'artist/album/song.mp3' will be processed
# into 'output_dir/album/'.

set -euo pipefail

# --- Configuration ---
DOCKER_IMAGE="aclmb/stemgen:latest"
CACHE_DIR="$HOME/.cache/stemgen_docker_cache"

# --- Functions ---

# Function to display usage information and exit.
usage() {
    echo "Usage: $0 -o <output_dir> [-f <input_file> | -p <playlist_file>] [-g]"
    echo "  -o <output_dir>      : Directory to store the output."
    echo "  -f <input_file>      : A single audio file to process."
    echo "  -p <playlist_file>   : A playlist file (e.g., m3u) with a list of audio files."
    echo "  -g                   : Use GPU for processing ('--gpus all' for Docker)."
    echo
    echo "This script uses Docker to run '${DOCKER_IMAGE}' for processing."
    echo "The container is expected to handle the demuxing and remuxing."
    exit 1
}

# Function to process a single audio file.
# Arguments:
#   $1: Path to the audio file.
#   $2: Base output directory.
process_file() {
    local song_path="$1"
    local base_output_dir="$2"

    echo "---"
    echo "Starting to process: $song_path"

    # Resolve absolute path for the song file. Exit if it doesn't exist.
    local abs_path
    if ! abs_path=$(realpath -e "$song_path" 2>/dev/null); then
        echo "Warning: Skipping '$song_path'. File not found or path is invalid." >&2
        return
    fi

    local dir_path
    dir_path=$(dirname "$abs_path")
    local filename
    filename=$(basename "$abs_path")
    # The parent directory of the song file (e.g., 'interpret' or 'album')
    local parent_dir
    parent_dir=$(basename "$dir_path")

    # The output subdirectory is the parent directory of the song file.
    local rel_output_dir="$parent_dir"

    echo "Processing: $filename"
    echo "  Source directory (mounted as /input): $dir_path"
    echo "  Output directory (mounted as /output): $base_output_dir"
    echo "  Output will be in container path: /output/$rel_output_dir"

    # Run the Docker container to process the file.
    # The container is expected to take an input file and an output directory.
    # The 'docker_gpu_args' is a global variable. We want word splitting here.
    # shellcheck disable=SC2086
    if ! docker run --rm ${docker_gpu_args} \
        -v "$dir_path:/input:ro" \
        -u "$(id -u):$(id -g)" \
        -v "$base_output_dir:/output" \
        -v "$CACHE_DIR:/home/stemgen/.cache:rw" \
        "${DOCKER_IMAGE}" \
        generate "/input/$filename" "/output/$rel_output_dir"; then
        echo "Error: Docker command failed for '$filename'." >&2
    else
        echo "Successfully processed '$filename'."
    fi
}

# --- Main Script ---

# Initialize variables
output_dir=""
input_file=""
playlist_file=""
docker_gpu_args=""

# Parse command-line options
while getopts ":o:f:p:g-" opt; do
    case ${opt} in
        o) output_dir=$OPTARG ;;
        f) input_file=$OPTARG ;;
        p) playlist_file=$OPTARG ;;
        g) docker_gpu_args="--gpus all" ;;
        -)
            case "${OPTARG}" in
                gpu)
                    docker_gpu_args="--gpus all"
                    ;;
                *)
                    echo "Invalid option: --${OPTARG}" >&2
                    usage
                    ;;
            esac
            ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
    esac
done

# --- Validation ---
if [[ -z "$output_dir" ]]; then
    echo "Error: Output directory must be specified with -o." >&2
    usage
fi

if [[ -n "$input_file" && -n "$playlist_file" ]] || [[ -z "$input_file" && -z "$playlist_file" ]]; then
    echo "Error: Please specify either an input file (-f) or a playlist (-p), but not both." >&2
    usage
fi

# Create output directory if it doesn't exist and resolve its absolute path
mkdir -p "$output_dir"
output_dir=$(realpath "$output_dir")

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# --- Execution ---
if [[ -n "$input_file" ]]; then
    process_file "$input_file" "$output_dir"
elif [[ -n "$playlist_file" ]]; then
    if [[ ! -f "$playlist_file" ]]; then
        echo "Error: Playlist file not found: $playlist_file" >&2
        exit 1
    fi

    playlist_abs_path=$(realpath "$playlist_file")
    playlist_dir=$(dirname "$playlist_abs_path")
    echo "Processing playlist: $playlist_abs_path"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then continue; fi
        song_path="$line"
        if [[ ! "$song_path" = /* ]]; then song_path="$playlist_dir/$song_path"; fi
        process_file "$song_path" "$output_dir"
    done < "$playlist_abs_path"
fi

echo "---"
echo "All tasks complete."
