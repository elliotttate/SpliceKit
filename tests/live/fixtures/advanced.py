"""Deterministic advanced FCPXML blueprint; import only with the isolated-library guard."""
from pathlib import Path
import xml.etree.ElementTree as ET

EFFECTS = {
    'gaussian': '.../Effects.localized/Blur.localized/Gaussian.localized/Gaussian.moef',
    'letterbox': '.../Effects.localized/Stylize.localized/Letterbox.localized/Letterbox.moef',
    'colorize': '.../Effects.localized/Color.localized/Colorize.localized/Colorize.moef',
    'title': '.../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti',
    'dissolve': 'FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265',
    'generator': '.../Generators.localized/Solids.localized/Custom.localized/Custom.motn',
}


def blueprint(media, library, project='SpliceKit-Test-Advanced-30'):
    root = ET.Element('fcpxml', version='1.14')
    res = ET.SubElement(root, 'resources')
    ET.SubElement(res, 'format', id='r1', width='360', height='640', frameDuration='1/30s', colorSpace='1-1-1 (Rec. 709)')
    asset = ET.SubElement(res, 'asset', id='r2', name='Original stereo bars', start='0s', duration='30s',
                          hasVideo='1', hasAudio='1', audioSources='1', audioChannels='2', audioRate='48000', format='r1')
    ET.SubElement(asset, 'media-rep', kind='original-media', src=Path(media).resolve().as_uri())
    refs = {}
    for i, (name, uid) in enumerate(EFFECTS.items(), 3):
        refs[name] = 'r'+str(i)
        ET.SubElement(res, 'effect', id=refs[name], name=name, uid=uid)
    lib = ET.SubElement(root, 'library', location=Path(library).resolve().as_uri())
    event = ET.SubElement(lib, 'event', name='SpliceKit-Test-Advanced')
    proj = ET.SubElement(event, 'project', name=project)
    seq = ET.SubElement(proj, 'sequence', format='r1', duration='15s', tcStart='0s', tcFormat='NDF', audioLayout='stereo', audioRate='48k')
    spine = ET.SubElement(seq, 'spine')
    first = ET.SubElement(spine, 'asset-clip', ref='r2', name='Trimmed stereo effects', offset='0s', start='10s', duration='6s', audioRole='dialogue')
    trans = ET.SubElement(first, 'adjust-transform', scale='1 1')
    param = ET.SubElement(trans, 'param', name='scale')
    anim = ET.SubElement(param, 'keyframeAnimation')
    ET.SubElement(anim, 'keyframe', time='12s', value='1 1', interp='ease', curve='smooth')
    ET.SubElement(anim, 'keyframe', time='13s', value='1.2 1.2', interp='linear')
    title = ET.SubElement(first, 'title', ref=refs['title'], name='Baseline title', lane='1', offset='10s', start='0s', duration='3s')
    text = ET.SubElement(title, 'text');ET.SubElement(text, 'text-style', ref='ts1').text='Hello world'
    style = ET.SubElement(title, 'text-style-def', id='ts1');ET.SubElement(style, 'text-style', font='Helvetica', fontSize='48', fontColor='1 1 1 1', alignment='center')
    cap = ET.SubElement(first, 'caption', name='English baseline', lane='1', offset='11s', start='0s', duration='2s', role='iTT.en')
    ET.SubElement(cap, 'text').text='Baseline caption'
    music = ET.SubElement(first, 'asset-clip', ref='r2', name='Music role fixture', lane='-1', offset='10s', start='0s', duration='1s', srcEnable='audio', audioRole='music')
    for index, name in enumerate(['gaussian','gaussian','letterbox','colorize']):
        effect = ET.SubElement(first, 'filter-video', ref=refs[name], name=name)
        if index == 1:
            ET.SubElement(effect, 'param', name='Amount', key='9999/986883370/100/986883376/2/100', value='0.7')
    second = ET.SubElement(spine, 'asset-clip', ref='r2', name='Clean right cut', offset='6s', start='5s', duration='3s', audioRole='dialogue')
    cap2 = ET.SubElement(second, 'caption', name='Turkish role fixture', lane='1', offset='5s', start='0s', duration='1s', role='iTT.tr')
    ET.SubElement(cap2, 'text').text='Türkçe'
    ET.SubElement(spine, 'asset-clip', ref='r2', name='Transition left', offset='9s', start='5s', duration='3s', audioRole='dialogue')
    transition = ET.SubElement(spine, 'transition', name='Cross Dissolve', offset='23/2s', duration='1s')
    ET.SubElement(transition, 'filter-video', ref=refs['dissolve'], name='Cross Dissolve')
    ET.SubElement(spine, 'asset-clip', ref='r2', name='Transition right', offset='12s', start='5s', duration='3s', audioRole='dialogue')
    ET.indent(root)
    return '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'+ET.tostring(root, encoding='unicode')+'\n'
