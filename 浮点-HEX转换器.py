
import tkinter as tk
from tkinter import ttk, messagebox
import struct
import numpy as np

def reset_fields():
    float_var.set("0")
    hex_var.set("0")

def float_to_hex():
    try:
        float_input = float_var.get().strip()
        if float_input == "":
            value = 0.0
        else:
            value = float(float_input)
    except ValueError:
        messagebox.showerror("错误", "无效的浮点数输入")
        return

    mode = mode_var.get()
    endian = endian_var.get()
    
    try:
        if mode == "half":
            arr = np.array([value], dtype='>f2' if endian == "big" else '<f2')
            b = arr.tobytes()
        elif mode == "single":
            b = struct.pack('!f' if endian == "big" else '<f', value)
        elif mode == "double":
            b = struct.pack('!d' if endian == "big" else '<d', value)
        else:
            messagebox.showerror("错误", "未知的模式")
            return
    except Exception as e:
        messagebox.showerror("错误", "转换失败: " + str(e))
        return

    hex_var.set(b.hex().upper())

def hex_to_float():
    mode = mode_var.get()
    endian = endian_var.get()
    expected_len = {"half": 4, "single": 8, "double": 16}[mode]
    
    hex_input = hex_var.get().strip().replace(" ", "").replace("0x", "").upper()
    if hex_input == "":
        hex_input = "0"
    
    if len(hex_input) < expected_len:
        hex_input = hex_input.zfill(expected_len)
    elif len(hex_input) > expected_len:
        hex_input = hex_input[-expected_len:]

    try:
        b = bytes.fromhex(hex_input)
        if mode == "half":
            value = np.frombuffer(b, dtype='>f2' if endian == "big" else '<f2')[0]
        elif mode == "single":
            value = struct.unpack('!f' if endian == "big" else '<f', b)[0]
        elif mode == "double":
            value = struct.unpack('!d' if endian == "big" else '<d', b)[0]
        else:
            messagebox.showerror("错误", "未知的模式")
            return
    except Exception as e:
        messagebox.showerror("错误", "转换失败: " + str(e))
        return

    float_var.set(str(value))

def validate_float_input(text):
    """ 只允许输入有效的浮点数（小数点在英文输入法下有效） """
    if text == "" or text == "-":  # 允许清空和输入负号
        return True
    try:
        float(text)  # 仅在浮点数格式正确时通过
        return True
    except ValueError:
        return False

def mode_changed():
    reset_fields()

root = tk.Tk()
root.title("浮点数-HEX码转换器")

mode_var = tk.StringVar(value="single")
endian_var = tk.StringVar(value="big")
float_var = tk.StringVar(value="0")
hex_var = tk.StringVar(value="0")

mode_frame = ttk.LabelFrame(root, text="浮点精度选择")
mode_frame.grid(row=0, column=0, columnspan=2, padx=10, pady=5, sticky="ew")

ttk.Radiobutton(mode_frame, text="半精度", variable=mode_var, value="half", command=mode_changed).grid(row=0, column=0, padx=5, pady=5)
ttk.Radiobutton(mode_frame, text="单精度", variable=mode_var, value="single", command=mode_changed).grid(row=0, column=1, padx=5, pady=5)
ttk.Radiobutton(mode_frame, text="双精度", variable=mode_var, value="double", command=mode_changed).grid(row=0, column=2, padx=5, pady=5)

endian_frame = ttk.LabelFrame(root, text="字节序")
endian_frame.grid(row=1, column=0, columnspan=2, padx=10, pady=5, sticky="ew")

ttk.Radiobutton(endian_frame, text="大端", variable=endian_var, value="big", command=mode_changed).grid(row=0, column=0, padx=5, pady=5)
ttk.Radiobutton(endian_frame, text="小端", variable=endian_var, value="little", command=mode_changed).grid(row=0, column=1, padx=5, pady=5)

ttk.Label(root, text="浮点数:").grid(row=2, column=0, padx=10, pady=5, sticky="e")
vcmd = root.register(validate_float_input)
float_entry = ttk.Entry(root, textvariable=float_var, validate="key", validatecommand=(vcmd, "%P"), width=30)
float_entry.grid(row=2, column=1, padx=10, pady=5, sticky="w")

btn_float_to_hex = ttk.Button(root, text="浮点转HEX码", command=float_to_hex)
btn_float_to_hex.grid(row=2, column=2, padx=10, pady=5, sticky="w")

ttk.Label(root, text="HEX码:").grid(row=3, column=0, padx=10, pady=5, sticky="e")
hex_entry = ttk.Entry(root, textvariable=hex_var, width=30)
hex_entry.grid(row=3, column=1, padx=10, pady=5, sticky="w")

btn_hex_to_float = ttk.Button(root, text="HEX转浮点", command=hex_to_float)
btn_hex_to_float.grid(row=3, column=2, padx=10, pady=5, sticky="w")

root.mainloop()
