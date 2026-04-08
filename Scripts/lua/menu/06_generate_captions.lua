-- Generate social-style captions on the timeline
sk.toast("Generating captions...")
sk.rpc("captions.setStyle", {preset_id = "bold_pop", position = "bottom"})
sk.rpc("captions.setGrouping", {mode = "social"})
sk.rpc("captions.generate", {style = "bold_pop"})
sk.alert("Captions", "Bold Pop captions generated and placed on the timeline.")
