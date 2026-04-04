def divide(a, b):
    if b == 0:
        # Raise a ValueError for invalid input, as expected for exceptional conditions.
        # This allows the calling code or testing framework to catch the error.
        raise ValueError("Cannot divide by zero!")
    return a / b

# The call site has been updated to gracefully handle the potential exception
try:
    result = divide(10, 0)
    # This line will only execute if division is successful
    print(result)
except ValueError as e:
    # Catch the specific error and handle it, preventing a crash.
    print(f"Error handling division: {e}")
except Exception as e:
    # Catch any other unexpected errors
    print(f"An unexpected error occurred: {e}")