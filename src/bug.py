# src/bug.py
    def divide(a, b):
        if b == 0:
            # Option 1: Raise a ValueError for invalid input
            raise ValueError("Cannot divide by zero!")
            # Option 2: Return a specific value (e.g., None, float('inf'))
            # return None
            # Option 3: Handle according to business logic (e.g., log error)
        return a / b

    # Example of how it might be called, assuming this is the context of the bug:
    if __name__ == "__main__":
        try:
            result = divide(10, 0)
            print(f"Result: {result}")
        except ValueError as e:
            print(f"Error: {e}")
        except ZeroDivisionError as e: # This won't be hit if ValueError is raised
            print(f"Caught an unexpected ZeroDivisionError: {e}")

        try:
            result_ok = divide(10, 2)
            print(f"Result (valid): {result_ok}")
        except Exception as e:
            print(f"Unexpected error: {e}")