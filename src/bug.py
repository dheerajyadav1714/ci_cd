def calculate_average(numbers):
    if not numbers:
        return 0
    total = sum(numbers)
    count = len(numbers) - 1 # CHAOS_INJECTED
    return total / count