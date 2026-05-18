#!/bin/bash

set -euo pipefail

# --- Configuration ---
#DOCKER_IMAGE="aclmb/stemgen:main-cuda"
DOCKER_IMAGE="aclmb/stemgen:latest-cuda"
CACHE_DIR="$HOME/.cache/stemgen_docker_cache"

# --- Functions ---

# Function to display usage information and exit.
usage() {
    echo "Usage: $0 [-o <output_dir>] [-b <track_list>] [<input_file>]"
    echo "  -h, --help             : Print this help message and exit."
    echo "  -o <output_dir>        : Directory to store the output. Defaults to the input file's directory."
    echo "  -b <track_list>        : A file containing a list of audio tracks to process."
    echo "  <input_file>           : A single audio file to process. Cannot be used with -b."
    echo "  --shifts <num>         : Number of random shifts for stabilization (improves quality, but is slower)."
    echo "  --use-alac             : Use lossless ALAC codec for stems instead of the default AAC."
    echo "  --overwrite            : Overwrite existing output files without asking."
    echo "  --update               : Download the latest stemgen Docker image and exit."
    echo
    echo "This script uses Docker to run '${DOCKER_IMAGE}' for processing."
    echo "The container is expected to handle the demuxing and remuxing."
    exit 1
}

# Function to force download the latest Docker image, showing all output.
force_update_image() {
    echo "Attempting to download the latest Docker image: ${DOCKER_IMAGE}..."
    # Run docker pull directly to show progress bars and all output.
    if docker pull "${DOCKER_IMAGE}"; then
        echo "Docker image pull command finished successfully."
    else
        echo "Error: Failed to pull Docker image '${DOCKER_IMAGE}'." >&2
        exit 1
    fi
}

# Function to check for image updates and pull if necessary.
# This version is quieter and intended for automatic checks.
check_for_update() {
    echo "Checking for updates for Docker image: ${DOCKER_IMAGE}..."

    local old_id
    old_id=$(docker images -q "${DOCKER_IMAGE}" 2>/dev/null || echo "")

    local pull_output
    pull_output=$(docker pull "${DOCKER_IMAGE}" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to pull Docker image '${DOCKER_IMAGE}'." >&2
        echo "Please check your internet connection and Docker setup." >&2
        echo "--- Docker Output ---" >&2
        echo "${pull_output}" >&2
        echo "---------------------" >&2
        exit 1
    fi

    local new_id
    new_id=$(docker images -q "${DOCKER_IMAGE}" 2>/dev/null || echo "")

    if [[ -z "$old_id" && -n "$new_id" ]]; then
        echo "Result: Successfully downloaded new image '${DOCKER_IMAGE}'."
    elif [[ "$old_id" != "$new_id" ]]; then
        echo "Result: Successfully downloaded an updated version of '${DOCKER_IMAGE}'."
    else
        echo "Result: The Docker image '${DOCKER_IMAGE}' is already up to date."
    fi
}

# Function to process a single audio file.
# Arguments:
#   $1: Path to the audio file.
#   $2: Base output directory.
#   $3: Overwrite flag ('true' or 'false').
process_file() {
    # These are passed from the main script's scope
    # shellcheck disable=SC2154
    local stemgen_args=("${stemgen_opts_array[@]}")
    local song_path="$1"
    local base_output_dir_arg="$2"
    local overwrite_flag="$3"

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

    local effective_output_dir
    local container_output_path

    if [[ -n "$base_output_dir_arg" ]]; then
        effective_output_dir="$base_output_dir_arg"
        container_output_path="/output"
        echo "  Output directory (mounted as /output): $effective_output_dir"
    else
        effective_output_dir="$dir_path"
        container_output_path="/output"
        echo "  Output directory (mounted as /output): $effective_output_dir (same as input)"
    fi

    # --- Pre-flight check for existing file ---
    # Construct the expected output filename. Assumes '.stem.mp4' suffix.
    local input_basename="${filename%.*}"
    local expected_output_file="$effective_output_dir/$input_basename.stem.mp4"

    if [[ -f "$expected_output_file" && "$overwrite_flag" != "true" ]]; then
        read -p "Warning: Output file '$expected_output_file' already exists. Overwrite? (y/N) " -n 1 -r
        echo # Move to a new line
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Skipping '$filename'."
            return
        else
            # User confirmed overwrite, so remove the file.
            echo "Removing existing file: $expected_output_file"
            rm -f "$expected_output_file"
        fi
    elif [[ -f "$expected_output_file" && "$overwrite_flag" == "true" ]]; then
        echo "Removing existing file as per --overwrite flag: $expected_output_file"
        rm -f "$expected_output_file"
    fi

    echo "Processing: $filename"
    echo "  Source directory (mounted as /input): $dir_path"

    # For debugging, print the exact command being run.
    echo "  Executing command: docker run --rm ${docker_gpu_args} -v \"$dir_path:/input:ro\" -v \"$effective_output_dir:/output\" -v \"$CACHE_DIR:/home/stemgen/.cache:rw\" \"${DOCKER_IMAGE}\" generate ${stemgen_opts_array[@]} \"/input/$filename\" \"$container_output_path\""

    # Run the Docker container to process the file.
    # The container is expected to take an input file and an output directory.
    # The 'docker_gpu_args' is a global variable. We want word splitting here.
    # We no longer use a TTY since we capture output, so the -t flag is removed.
    # shellcheck disable=SC2086,SC2068
    local docker_output
    # We capture all output to display it in case of an error.
    # A side effect is that the interactive progress bar will not be displayed in real-time.
    if ! docker_output=$(docker run --rm ${docker_gpu_args} \
        -v "$dir_path:/input:ro" \
        -v "$effective_output_dir:/output" \
        -v "$CACHE_DIR:/home/stemgen/.cache:rw" \
        "${DOCKER_IMAGE}" generate "${stemgen_args[@]}" "/input/$filename" \
        "$container_output_path" 2>&1); then
        echo "Error: Docker command failed for '$filename'." >&2
        echo "--- Docker Output ---" >&2
        echo "${docker_output}" >&2
        echo "---------------------" >&2
    else
        echo "Successfully processed '$filename'."
    fi
}

# --- Main Script ---

# Initialize variables
output_dir=""
track_list_file=""
overwrite_flag="false"

# --- Argument Parsing ---
input_file=""
declare -a stemgen_opts_array=()
update_only_flag="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -o)
            if [[ -n "$2" ]]; then
                output_dir="$2"
                shift 2
            else
                echo "Error: Option -o requires an argument." >&2
                usage
            fi
            ;;
        -b)
            if [[ -n "$2" ]]; then
                track_list_file="$2"
                shift 2
            else
                echo "Error: Option -b requires an argument." >&2
                usage
            fi
            ;;
        --shifts)
            if [[ -n "$2" ]]; then
                stemgen_opts_array+=(--shifts "$2")
                shift 2
            else
                echo "Error: Option --shifts requires an argument." >&2; usage
            fi
            ;;
        --use-alac)
            stemgen_opts_array+=(--use-alac)
            shift
            ;;
        --overwrite)
            overwrite_flag="true"
            shift
            ;;
        --update)
            update_only_flag="true"
            shift
            ;;
        -*)
            echo "Error: Invalid option '$1'." >&2
            usage
            ;;
        *)
            if [[ -n "$input_file" ]]; then
                echo "Error: Only one input file can be specified." >&2
                usage
            fi
            input_file="$1"
            shift
            ;;
    esac
done

# --- Update and Exit if --update is passed ---
if [[ "$update_only_flag" == "true" ]]; then
    force_update_image
    exit 0
fi

# --- Validation ---
if [[ -z "$input_file" && -z "$track_list_file" ]]; then
    echo "Error: You must specify either an input file or a track list with -b." >&2
    usage
fi

# Automatically detect GPU and set Docker arguments
check_for_update

if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected. Verifying Docker GPU support..."
    # Attempt a dry-run with a minimal CUDA image to see if Docker GPU support is functional.
    if docker run --rm --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi &> /dev/null; then
        echo "Docker GPU support confirmed. Using GPU for processing."
        docker_gpu_args="--gpus all"
    else
        echo "Warning: Docker GPU support check failed. This may be due to a missing 'nvidia-container-toolkit'." >&2
        echo "Falling back to CPU processing. The script will continue without GPU acceleration." >&2
        docker_gpu_args=""
    fi
else
    echo "No NVIDIA GPU detected. Using CPU for processing."
    docker_gpu_args=""
fi

# If output_dir is provided, create it and resolve its absolute path
if [[ -n "$output_dir" ]]; then
    mkdir -p "$output_dir"
    output_dir=$(realpath "$output_dir")
fi

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# --- Execution ---
if [[ -n "$input_file" ]]; then
    process_file "$input_file" "$output_dir" "$overwrite_flag"
elif [[ -n "$track_list_file" ]]; then
    if [[ ! -f "$track_list_file" ]]; then
        echo "Error: Track list file not found: $track_list_file" >&2
        exit 1
    fi

    track_list_abs_path=$(realpath "$track_list_file")
    track_list_dir=$(dirname "$track_list_abs_path")
    echo "Processing track list: $track_list_abs_path"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then continue; fi
        song_path="$line"
        if [[ ! "$song_path" = /* ]]; then song_path="$track_list_dir/$song_path"; fi
        process_file "$song_path" "$output_dir" "$overwrite_flag"
    done < "$track_list_abs_path"
fi

echo "---"
echo "All tasks complete."
