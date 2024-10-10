# Example of running a function with pkexec
privileged_function() {
    # Commands that require elevated privileges
    losetup -fP --show "$1"
    # ...
}

# Call the function using pkexec
pkexec bash -c "$(declare -f privileged_function); privileged_function '$FILEPATH'"
