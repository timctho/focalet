import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ThemeColorPicker extends StatefulWidget {
  const ThemeColorPicker({required this.initialColor, super.key});
  final Color initialColor;
  @override
  State<ThemeColorPicker> createState() => _ThemeColorPickerState();
}

class _ThemeColorPickerState extends State<ThemeColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initialColor);
  late final _hex = TextEditingController(text: _format(widget.initialColor));
  bool _valid = true;
  String _format(Color color) => (color.toARGB32() & 0xffffff)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
  void _update(HSVColor value) => setState(() {
    _hsv = value;
    _valid = true;
    _hex.text = _format(value.toColor());
  });
  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('theme-color-picker'),
    title: const Text('Custom color'),
    content: SizedBox(
      width: 290,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              void select(Offset offset) => _update(
                _hsv
                    .withSaturation((offset.dx / width).clamp(0, 1))
                    .withValue((1 - offset.dy / 150).clamp(0, 1)),
              );
              return Semantics(
                label: 'Color palette',
                child: GestureDetector(
                  key: const ValueKey('color-saturation-value'),
                  onTapDown: (d) => select(d.localPosition),
                  onPanUpdate: (d) => select(d.localPosition),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      height: 150,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white,
                                    HSVColor.fromAHSV(
                                      1,
                                      _hsv.hue,
                                      1,
                                      1,
                                    ).toColor(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: _hsv.saturation * (width - 12),
                            top: (1 - _hsv.value) * 138,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black54,
                                    blurRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Hue'),
              Expanded(
                child: Slider(
                  key: const ValueKey('color-hue'),
                  value: _hsv.hue,
                  min: 0,
                  max: 360,
                  activeColor: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                  onChanged: (hue) => _update(_hsv.withHue(hue)),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('color-hex'),
                  controller: _hex,
                  maxLength: 6,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Hex color',
                    prefixText: '#',
                    counterText: '',
                    errorText: _valid ? null : 'Enter six hex digits',
                  ),
                  onChanged: (text) => setState(() {
                    _valid = text.length == 6;
                    if (_valid) {
                      _hsv = HSVColor.fromColor(
                        Color(0xff000000 | int.parse(text, radix: 16)),
                      );
                    }
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('apply-custom-color'),
        onPressed: _valid ? () => Navigator.pop(context, _hsv.toColor()) : null,
        child: const Text('Use color'),
      ),
    ],
  );
}
