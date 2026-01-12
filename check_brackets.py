
import sys

def find_imbalance(filename):
    with open(filename, 'r', encoding='utf-8') as f:
        content = f.read()
    
    stack = []
    in_string = False
    escaped = False
    in_comment = False
    
    for i, char in enumerate(content):
        if escaped:
            escaped = False
            continue
        if char == '\\':
            escaped = True
            continue
        
        if in_comment:
            if char == '\n':
                in_comment = False
            continue
        
        if char == '"':
            in_string = not in_string
            continue
        
        if in_string:
            continue
            
        if char == ';':
            # Check if this is the start of a comment
            in_comment = True
            continue
            
        if char == '(':
            stack.append(i)
        elif char == ')':
            if not stack:
                print(f"Extra closing bracket at position {i}")
                # Find line number
                line = content.count('\n', 0, i) + 1
                col = i - content.rfind('\n', 0, i)
                print(f"Line {line}, Col {col}")
                return
            stack.pop()
            
    if stack:
        for pos in stack:
            print(f"Unclosed opening bracket at position {pos}")
            line = content.count('\n', 0, pos) + 1
            col = pos - content.rfind('\n', 0, pos)
            print(f"Line {line}, Col {col}")
    else:
        print("Balanced!")

if __name__ == "__main__":
    find_imbalance(sys.argv[1])
