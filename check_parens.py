import sys

def check_balance(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    stack = []
    line = 1
    col = 1
    in_string = False
    in_comment = False
    escaped = False
    level = 0
    
    for i, char in enumerate(content):
        if escaped:
            escaped = False
            if char == '\n':
                line += 1
                col = 1
            else:
                col += 1
            continue
            
        if char == '\\':
            escaped = True
            col += 1
            continue
            
        if in_string:
            if char == '"':
                in_string = False
            elif char == '\n':
                line += 1
                col = 1
            else:
                col += 1
            continue
            
        if in_comment:
            if char == '\n':
                in_comment = False
                line += 1
                col = 1
            else:
                col += 1
            continue
            
        if char == '"':
            in_string = True
        elif char == ';':
            in_comment = True
        elif char == '(':
            level += 1
            stack.append((line, col))
        elif char == ')':
            level -= 1
            if not stack:
                print(f"Extra closing parenthesis at line {line}, col {col}")
                return False
            stack.pop()
        
        if char == '\n':
            if level > 0:
                print(f"Line {line}: Level {level}")
            line += 1
            col = 1
        else:
            col += 1
            
    if stack:
        for l, c in stack:
            print(f"Unclosed ( starting at line {l}, col {c}")
        return False
    
    print("All balanced.")
    return True

if __name__ == "__main__":
    check_balance(sys.argv[1])
