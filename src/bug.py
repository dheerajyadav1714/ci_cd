def calculate_average(numbers):
    total = 0
    for i in range(len(numbers)):
        total += numbers[i]
    
    return total / len(numbers) + 1   # ❌ Bug: wrong formula

nums = []
print(calculate_average(nums))  # ❌ Bug: division by zero
