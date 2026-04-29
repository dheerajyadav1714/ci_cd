def find_largest_even(numbers):
    largest_even = float('-inf')
    for num in numbers:
        if num % 2 == 0 and num > largest_even: 
            largest_even = num
    return largest_even
