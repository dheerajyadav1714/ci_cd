def calculate_average(numbers):
    if not numbers:
        raise ValueError("Cannot calculate average of an empty list")
    total = 0
    for number in numbers:
        total += number
    
    return total / len(numbers)