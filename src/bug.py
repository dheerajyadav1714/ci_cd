def calculate_average(numbers):
    if not numbers:
        return None
    total = 0
    for i in range(len(numbers)):
        total += numbers[i]
    
    return total / len(numbers)

nums = []
print(calculate_average(nums))