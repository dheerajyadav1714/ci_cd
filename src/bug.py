# Calculator module
def add(a, b):
    return a + b
def subtract(a, b):
    return a - b
def divide(a, b):
    if b == 0:
        return "Error: Cannot divide by zero"
    return a / b
def multiply(a, b):
    return a * b
if __name__ == "__main__":
    print("10 / 0 =", divide(10, 0))