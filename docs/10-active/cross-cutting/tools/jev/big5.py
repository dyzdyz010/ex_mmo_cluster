"""只测试：按 Serapio-García 等（arXiv 2307.00184 附录 K.1、表 13；Nature Machine Intelligence 2025）的人格塑造写法生成人格描述。
52 对低 / 高标记形容词（Goldberg 双极形容词扩充，对应 IPIP-NEO 的 5 个维度、30 个子维度）× 9 级强度修饰词。
角色卡分两段：
  traits   严格的标准框架，形式永不变化：键只能是 PAIRS 里的 52 个高标记形容词，值是 1..9 的整数，由 render 统一渲染；
           没写的形容词不出现在描述里。
  personal 自由英文文本，高度个性化：偏好、承诺、目标、对重复的态度等标准表覆盖不了的内容。
describe(card) 把整张卡转成人格句：'<who>. Personality: <traits>. Personal: <personal>'。"""

PAIRS = {
    'EXT': [('unfriendly', 'friendly'), ('introverted', 'extraverted'), ('silent', 'talkative'), ('timid', 'bold'),
            ('unassertive', 'assertive'), ('inactive', 'active'), ('unenergetic', 'energetic'),
            ('unadventurous', 'adventurous and daring'), ('gloomy', 'cheerful')],
    'AGR': [('distrustful', 'trustful'), ('immoral', 'moral'), ('dishonest', 'honest'), ('unkind', 'kind'),
            ('stingy', 'generous'), ('unaltruistic', 'altruistic'), ('uncooperative', 'cooperative'),
            ('self-important', 'humble'), ('unsympathetic', 'sympathetic'), ('selfish', 'unselfish'),
            ('disagreeable', 'agreeable')],
    'CON': [('unsure', 'self-efficacious'), ('messy', 'orderly'), ('irresponsible', 'responsible'), ('lazy', 'hardworking'),
            ('undisciplined', 'self-disciplined'), ('impractical', 'practical'), ('extravagant', 'thrifty'),
            ('disorganized', 'organized'), ('negligent', 'conscientious'), ('careless', 'thorough')],
    'NEU': [('relaxed', 'tense'), ('at ease', 'nervous'), ('easygoing', 'anxious'), ('calm', 'angry'),
            ('patient', 'irritable'), ('happy', 'depressed'), ('unselfconscious', 'self-conscious'),
            ('level-headed', 'impulsive'), ('contented', 'discontented'), ('emotionally stable', 'emotionally unstable')],
    'OPE': [('unimaginative', 'imaginative'), ('uncreative', 'creative'),
            ('artistically unappreciative', 'artistically appreciative'), ('unaesthetic', 'aesthetic'),
            ('unreflective', 'reflective'), ('emotionally closed', 'emotionally aware'), ('uninquisitive', 'curious'),
            ('predictable', 'spontaneous'), ('unintelligent', 'intelligent'), ('unanalytical', 'analytical'),
            ('unsophisticated', 'sophisticated'), ('socially conservative', 'socially progressive')],
}
LOW = {high: low for pairs in PAIRS.values() for low, high in pairs}


def phrase(high, level):
    """9 级：1 extremely 低 … 4 a bit 低，5 neither 低 nor 高，6 a bit 高 … 9 extremely 高。"""
    low = LOW[high]
    if level == 5:
        return 'neither %s nor %s' % (low, high)
    word, distance = (low, 5 - level) if level < 5 else (high, level - 5)
    return ['a bit ', '', 'very ', 'extremely '][distance - 1] + word


def render(card):
    return ', '.join(phrase(high, level) for high, level in card.items())


def domain(name, level):
    """单维度塑造：该维度全部形容词取同一级。"""
    return {high: level for _, high in PAIRS[name]}


CARDS = {
    'lin': {'who': 'Lin, a builder',
            'traits': {'impulsive': 2, 'thrifty': 8, 'organized': 8, 'thorough': 8,
                       'responsible': 9, 'extraverted': 3, 'talkative': 3},
            'personal': 'Dislikes crowds and noise. Always keeps the promises she makes.'},
    'garrick': {'who': 'Garrick, a hunter',
                'traits': {'bold': 8, 'adventurous and daring': 9, 'impulsive': 8, 'energetic': 8, 'thrifty': 3},
                'personal': 'Loves meat, strong drink and a good fight. Gets bored by routine.'},
    'sella': {'who': 'Sella, a weaver',
              'traits': {'friendly': 9, 'extraverted': 8, 'talkative': 8, 'kind': 8, 'generous': 8, 'altruistic': 8},
              'personal': 'Loves gossip and hates being alone. Will drop her own work to help a friend.'},
    'ode': {'who': 'Ode, a tinkerer',
            'traits': {'curious': 9, 'imaginative': 8, 'analytical': 8, 'organized': 3, 'conscientious': 3},
            'personal': 'Forgets meals and chores when something puzzles him.'},
    'hask': {'who': 'Hask, a farmhand',
             'traits': {'hardworking': 2, 'active': 2, 'adventurous and daring': 3, 'anxious': 3, 'tense': 3},
             'personal': 'Does the least that lets him get by.'},
    'brenna': {'who': 'Brenna, a mason',
               'traits': {'humble': 2, 'assertive': 8, 'hardworking': 9, 'bold': 7, 'self-efficacious': 8},
               'personal': 'Wants to be known as the best in the village. Cannot stand losing or looking weak.'},
}


def describe(card, personal=True):
    text = '%s. Personality: %s.' % (card['who'], render(card['traits']))
    if personal and card['personal']:
        text += ' Personal: ' + card['personal']
    return text
