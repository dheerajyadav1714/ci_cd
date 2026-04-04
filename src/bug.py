def divide(a, b):
    if b == 0:
        print("Error: Cannot divide by zero!")
        return None  # Return None or raise a ValueError for invalid input
    return a / b

# The original call site is modified to handle the potential None return
result = divide(10, 0)
if result is not None:
    print(result)