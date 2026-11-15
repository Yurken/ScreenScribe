import SwiftUI
import AppKit
import ScreenScribeCore

private let accent = Color(red:0.12,green:0.65,blue:0.69)

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 24
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius:radius).stroke(.white.opacity(0.3),lineWidth:0.75))
        }
    }
}

struct ControlPanel: View {
    @ObservedObject var controller: PresentationController
    @State private var tab = 0
    var body: some View {
        VStack(spacing:18) {
            HStack(spacing:11) {
                Image(systemName:"pencil.tip.crop.circle.fill").font(.system(size:31)).foregroundStyle(accent)
                VStack(alignment:.leading,spacing:2) {
                    Text("屏注").font(.system(size:21,weight:.semibold))
                    Text("ScreenScribe").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("LOCAL").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(1.5).foregroundStyle(.secondary)
            }
            Picker("面板",selection:$tab) { Text("演示").tag(0);Text("设置").tag(1) }.pickerStyle(.segmented).labelsHidden()
            if tab == 0 { presentation } else { settings }
            if let message = controller.message { Text(message).font(.caption).foregroundStyle(accent).lineLimit(2) }
            HStack {
                Text("v0.1.0").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(width:378).background(.clear).tint(accent)
    }
    var presentation: some View {
        VStack(spacing:14) {
            Button { Task { await controller.begin() } } label: {
                HStack {
                    Image(systemName:controller.autoFreeze ? "snowflake" : "pencil.tip").font(.title2)
                    VStack(alignment:.leading,spacing:3) {
                        Text(controller.autoFreeze ? "冻结并开始批注" : "开始实时批注").font(.system(size:15,weight:.semibold))
                        Text(controller.autoFreeze ? "固定当前画面，安心讲解" : "在任意应用上书写").font(.system(size:11)).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName:"arrow.up.right").font(.system(size:16,weight:.medium))
                }.foregroundStyle(.white).padding(16).background(accent.gradient,in:RoundedRectangle(cornerRadius:19))
            }.buttonStyle(.plain).disabled(controller.busy)
            HStack(spacing:8) {
                actionTile("实时","pencil.tip") { Task { await controller.begin(.live) } }
                actionTile("白板","rectangle.inset.filled") { Task { await controller.begin(.whiteboard) } }
                actionTile("黑板","rectangle.fill") { Task { await controller.begin(.blackboard) } }
                actionTile("截图","crop") { Task { await controller.snip() } }
            }
            Divider().opacity(0.5)
            HStack(spacing:8) {
                effectTile("聚光灯","flashlight.on.fill",active:controller.spotlight) { controller.spotlight.toggle() }
                effectTile("光标高亮","cursorarrow.rays",active:controller.cursorHighlight) { controller.cursorHighlight.toggle() }
                effectTile("放大镜","plus.magnifyingglass",active:controller.lens) { Task { await controller.setLens(!controller.lens) } }
            }
            RecordingControls(controller:controller,recording:controller.recording)
            HStack {
                Image(systemName:"cup.and.saucer").foregroundStyle(.secondary)
                Text("课间休息").font(.system(size:12,weight:.medium))
                Spacer()
                Stepper(value:$controller.breakMinutes,in:1...120,step:1) { Text("\(Int(controller.breakMinutes)) 分钟").font(.system(size:11)).monospacedDigit() }.frame(width:130)
                Button("开始") { controller.startBreak() }.controlSize(.small)
            }.padding(12).modifier(GlassSurface(radius:15))
            if controller.active {
                Button("\(controller.active ? "隐藏" : "显示")批注 · 保留内容") { controller.toggleSession(); controller.closePanel?() }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
    var settings: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Toggle("开始批注时自动冻结画面",isOn:$controller.autoFreeze)
                Toggle("隐藏桌面图标",isOn:$controller.hideDesktop)
                VStack(alignment:.leading,spacing:8) {
                    Text("聚光灯").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("范围"); Slider(value:$controller.focusRadius,in:60...320) }
                    HStack { Text("暗度"); Slider(value:$controller.dimOpacity,in:0.2...0.85) }
                    HStack { Text("放大"); Slider(value:$controller.lensZoom,in:1.5...4,step:0.5); Text(String(format:"%.1f×",controller.lensZoom)).monospacedDigit().frame(width:36) }
                }
                Divider()
                ShortcutSettings(manager:controller.hotkeys)
                Divider()
                Button("屏幕录制权限…") { controller.openScreenPermissionSettings() }
                Text("批注保存在当前会话，退出前可导出 PNG。屏幕与录音仅保存在本机。").font(.caption2).foregroundStyle(.secondary)
            }.font(.system(size:12)).padding(.trailing,4)
        }.frame(height:426)
    }
    func actionTile(_ label:String,_ symbol:String,action:@escaping()->Void)->some View {
        Button(action:action) { VStack(spacing:7) { Image(systemName:symbol).font(.system(size:19));Text(label).font(.system(size:11,weight:.medium)) }.frame(maxWidth:.infinity).frame(height:68).contentShape(RoundedRectangle(cornerRadius:15)) }.buttonStyle(.plain).modifier(GlassSurface(radius:15))
    }
    func effectTile(_ label:String,_ symbol:String,active:Bool,action:@escaping()->Void)->some View {
        Button(action:action) { VStack(spacing:6) { Image(systemName:symbol).font(.system(size:19));Text(label).font(.system(size:10,weight:.medium)) }.foregroundStyle(active ? accent : .primary).frame(maxWidth:.infinity).frame(height:64).background(active ? accent.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:15)) }.buttonStyle(.plain).modifier(GlassSurface(radius:15))
    }
}

struct RecordingControls: View {
    @ObservedObject var controller: PresentationController
    @ObservedObject var recording: RecordingService
    var body: some View {
        HStack(spacing:10) {
            Button { controller.toggleRecording() } label: {
                HStack(spacing:7) {
                    Image(systemName:recording.isRecording ? "stop.circle.fill" : "record.circle").foregroundStyle(.red)
                    Text(recording.isRecording ? "停止 · \(clock)" : "录屏").font(.system(size:12,weight:.semibold)).monospacedDigit()
                }
            }.buttonStyle(.plain).disabled(recording.isBusy)
            Spacer()
            Toggle(isOn:$controller.includeSystemAudio) { Image(systemName:"speaker.wave.2").help("录制系统声音") }.toggleStyle(.checkbox).labelsHidden().help("系统声音")
            Image(systemName:"speaker.wave.2").foregroundStyle(controller.includeSystemAudio ? accent : .secondary).font(.caption)
            Toggle(isOn:$controller.includeMicrophone) { Text("麦克风") }.toggleStyle(.checkbox).labelsHidden().help("麦克风")
            Image(systemName:"mic").foregroundStyle(controller.includeMicrophone ? accent : .secondary).font(.caption)
        }.padding(13).modifier(GlassSurface(radius:15))
    }
    var clock:String { String(format:"%02d:%02d",Int(recording.elapsed)/60,Int(recording.elapsed)%60) }
}

struct ShortcutSettings: View {
    @ObservedObject var manager: HotKeyManager
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("全局快捷键").font(.caption).foregroundStyle(.secondary)
            ForEach(GlobalAction.allCases) { action in
                HStack { Text(action.title); Spacer(); ShortcutRecorder(title:manager.bindings[action.rawValue]?.display ?? "设置") { manager.set($0,for:action) }.frame(width:106,height:25) }
            }
            if let error = manager.registrationError { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
    }
}

struct AnnotationToolbar: View {
    @ObservedObject var controller: PresentationController
    @ObservedObject var document: CanvasDocument
    let palette:[NSColor] = [.systemRed,.systemOrange,.systemYellow,.systemGreen,.systemTeal,.systemBlue,.systemPurple,.white,.black]
    var body: some View {
        VStack(spacing:9) {
            HStack(spacing:4) {
                Image(systemName:"circle.grid.2x3.fill").foregroundStyle(.tertiary).font(.system(size:13)).padding(.horizontal,5).help("拖动工具条")
                ForEach(AnnotationTool.allCases) { tool in
                    toolButton(tool.symbol,tool.label+" ("+tool.shortcut.uppercased()+")",selected:document.tool == tool) { controller.selectTool(tool) }
                }
                separator
                toolButton("arrow.uturn.backward","撤销 ⌘Z") { controller.undo() }.disabled(!document.canUndo)
                toolButton("arrow.uturn.forward","重做 ⇧⌘Z") { controller.redo() }.disabled(!document.canRedo)
                toolButton("trash","清空批注") { controller.clear() }
                Spacer(minLength:4)
                Menu {
                    ForEach(CanvasMode.allCases) { mode in Button(mode.title) { Task { await controller.begin(mode) } } }
                } label: { Label(controller.mode.title,systemImage:controller.mode.symbol).font(.system(size:11,weight:.medium)) }.menuStyle(.borderlessButton).fixedSize()
                toolButton(controller.passThrough ? "cursorarrow" : "hand.point.up.left","穿透鼠标，操作后面的应用",selected:controller.passThrough) { controller.passThrough.toggle() }
                Menu {
                    Button("复制截图 ⌘C") { Task { await controller.export(save:false) } }
                    Button("保存 PNG… ⌘S") { Task { await controller.export(save:true) } }
                    Button("区域截图…") { Task { await controller.snip() } }
                    Button(controller.recording.isRecording ? "停止并保存录屏" : "开始录屏…") { controller.toggleRecording() }
                    Divider()
                    Button(controller.lens ? "关闭放大镜" : "放大镜") { Task { await controller.setLens(!controller.lens) } }
                    Button(controller.spotlight ? "关闭聚光灯" : "聚光灯") { controller.spotlight.toggle() }
                    Button(controller.cursorHighlight ? "关闭光标高亮" : "光标高亮") { controller.cursorHighlight.toggle() }
                    Divider()
                    Button("控制面板…") { controller.showPanel?() }
                } label: { Image(systemName:"ellipsis.circle").font(.system(size:17)) }.menuStyle(.borderlessButton).frame(width:27)
                toolButton("xmark","隐藏批注 Esc") { controller.hideSession() }
            }
            HStack(spacing:8) {
                ForEach(Array(palette.enumerated()),id:\.offset) { _,color in
                    Button { document.color = color; controller.applyStyle(); controller.focusCanvas() } label: {
                        Circle().fill(Color(nsColor:color)).frame(width:17,height:17)
                            .overlay(Circle().strokeBorder(.gray.opacity(0.3),lineWidth:0.7))
                            .padding(3).overlay(Circle().stroke(document.color.isEqual(color) ? accent : .clear,lineWidth:1.5))
                    }.buttonStyle(.plain).accessibilityLabel("颜色 \(color.accessibilityName)")
                }
                ColorPicker("自定义颜色",selection:Binding(get:{Color(nsColor:document.color)},set:{document.color = NSColor($0);controller.applyStyle()}),supportsOpacity:true).labelsHidden().frame(width:25)
                separator
                if document.tool == .text || document.selectedAnnotation?.tool == .text {
                    textFormatting
                } else {
                    ForEach([2.0,4.0,8.0,14.0],id:\.self) { width in
                        Button { document.strokeWidth = width;controller.applyStyle();controller.focusCanvas() } label: {
                            Circle().fill(document.strokeWidth == width ? accent : Color.primary.opacity(0.6)).frame(width:width+3,height:width+3).frame(width:24,height:24)
                        }.buttonStyle(.plain).help("线宽 \(Int(width))")
                    }
                    Toggle(isOn:$document.fillShapes) { Image(systemName:"square.fill").font(.system(size:12)) }.toggleStyle(.button).buttonStyle(.plain).onChange(of:document.fillShapes) { _,_ in controller.applyStyle() }.help("填充形状")
                }
                Spacer(minLength:0)
                if let message = controller.message { Text(message).font(.system(size:10)).foregroundStyle(accent).lineLimit(1) }
                else { Text(controller.passThrough ? "鼠标穿透中" : "⇧ 约束形状 · 双击编辑文字").font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }.padding(.horizontal,14).padding(.vertical,12).modifier(GlassSurface(radius:25)).padding(3).tint(accent)
    }
    var textFormatting: some View {
        HStack(spacing:6) {
            Picker("字体",selection:$document.fontFamily) {
                Text("黑体").tag("Sans");Text("宋体").tag("Serif");Text("等宽").tag("Mono");Text("圆体").tag("Rounded")
            }.labelsHidden().frame(width:70).onChange(of:document.fontFamily) { _,_ in controller.applyStyle() }
            Picker("字号",selection:$document.fontSize) { ForEach([16.0,20,24,28,36,48,64,96],id:\.self) { Text("\(Int($0))").tag(CGFloat($0)) } }.labelsHidden().frame(width:56).onChange(of:document.fontSize) { _,_ in controller.applyStyle() }
            formatButton("bold",value:$document.textBold)
            formatButton("italic",value:$document.textItalic)
            formatButton("underline",value:$document.textUnderline)
            formatButton("highlighter",value:$document.textBackground)
        }
    }
    var separator: some View { Rectangle().fill(.primary.opacity(0.1)).frame(width:1,height:20).padding(.horizontal,4) }
    func toolButton(_ icon:String,_ help:String,selected:Bool=false,action:@escaping()->Void)->some View {
        Button(action:action) { Image(systemName:icon).font(.system(size:16,weight:.medium)).foregroundStyle(selected ? accent : Color.primary.opacity(0.8)).frame(width:32,height:32).background(selected ? accent.opacity(0.16) : Color.clear,in:RoundedRectangle(cornerRadius:10)) }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
    func formatButton(_ icon:String,value:Binding<Bool>)->some View {
        Button { value.wrappedValue.toggle(); controller.applyStyle() } label: { Image(systemName:icon).font(.system(size:12,weight:.semibold)).frame(width:23,height:25).background(value.wrappedValue ? accent.opacity(0.18) : .clear,in:RoundedRectangle(cornerRadius:6)) }.buttonStyle(.plain).help(icon)
    }
}

struct BreakScreen: View {
    @ObservedObject var controller: PresentationController
    var body: some View {
        ZStack {
            LinearGradient(colors:[Color(red:0.02,green:0.08,blue:0.13),Color(red:0.03,green:0.24,blue:0.29),Color(red:0.08,green:0.12,blue:0.25)],startPoint:.topLeading,endPoint:.bottomTrailing)
            Ellipse().fill(.cyan.opacity(0.15)).frame(width:700,height:400).blur(radius:100).offset(x:200,y:180)
            VStack(spacing:34) {
                Text("稍作休息").font(.system(size:22,weight:.medium)).tracking(8).foregroundStyle(.white.opacity(0.7))
                HStack(spacing:26) {
                    timerRing(Int(ceil(controller.breakRemaining))/3600,"小时",fraction:controller.breakRemaining/3600,color:.cyan)
                    timerRing(Int(ceil(controller.breakRemaining))%3600/60,"分钟",fraction:controller.breakRemaining.truncatingRemainder(dividingBy:3600)/3600,color:.teal)
                    timerRing(Int(ceil(controller.breakRemaining))%60,"秒",fraction:controller.breakRemaining.truncatingRemainder(dividingBy:60)/60,color:.mint)
                }
                Button("继续演示") { controller.endBreak() }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).padding(.horizontal,24).padding(.vertical,12).modifier(GlassSurface(radius:30))
            }
            VStack { HStack { TimelineView(.periodic(from:.now,by:1)) { context in Text(context.date,style:.time).font(.system(size:14,weight:.medium,design:.monospaced)).foregroundStyle(.white.opacity(0.6)) };Spacer();Button { controller.endBreak() } label:{Image(systemName:"xmark").foregroundStyle(.white.opacity(0.7))}.buttonStyle(.plain) };Spacer() }.padding(30)
        }.ignoresSafeArea()
    }
    func timerRing(_ value:Int,_ label:String,fraction:Double,color:Color)->some View {
        ZStack {
            Circle().stroke(.white.opacity(0.07),lineWidth:5)
            Circle().trim(from:0,to:min(1,max(0,fraction))).stroke(color.opacity(0.8),style:StrokeStyle(lineWidth:5,lineCap:.round)).rotationEffect(.degrees(-90))
            VStack(spacing:7) { Text(String(format:"%02d",value)).font(.system(size:54,weight:.light,design:.rounded)).monospacedDigit();Text(label).font(.system(size:12)).foregroundStyle(.white.opacity(0.5)) }.foregroundStyle(.white)
        }.frame(width:165,height:165)
    }
}
