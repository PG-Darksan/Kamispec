from PIL import Image
import os

# ファイル名の設定 (jpgに変更)
input_file = 'image.jpg'  # ※もし拡張子が .jpeg の場合は 'image.jpeg' に変更してください
output_file = 'image.ico' 

def convert_jpg_to_ico():
    # 同じ階層にファイルが存在するか確認
    if not os.path.exists(input_file):
        print(f"エラー: '{input_file}' が見つかりません。")
        return

    try:
        # 画像を開く (Pillowは自動的にJPG形式を認識してくれます)
        img = Image.open(input_file)
        
        # アイコンとして保存（sizesを指定するとWindows等で綺麗に表示されます）
        img.save(output_file, format='ICO', sizes=[(256, 256)])
        print(f"成功: '{input_file}' を '{output_file}' に変換しました！")
        
    except Exception as e:
        print(f"エラーが発生しました: {e}")

if __name__ == "__main__":
    convert_jpg_to_ico()