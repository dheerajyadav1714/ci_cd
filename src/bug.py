def calculate_average(numbers):
    if not numbers:
        return 0  # Handle empty list gracefully, returning 0 or raising an error
    
    total = 0
    for number in numbers:
        total += number
    
    return total / len(numbers)

nums = []
print(calculate_average(nums))