class_name WhyText
extends RefCounted

## The selected animal's last decision in words, for the card's «Почему:» line. The AI writes
## its reasons for the developer panel in a fixed form (`ActionSelector`): «selected drink at
## 0.62 (thirst 0.80, water 0.91)», «dropped graze (below hunger floor); selected …», «kept graze
## as top action», and the reasons that skip the selector - «danger or recent threat»,
## «engaged flow: chase». This reads that form back into Russian: «перестала пастись —
## наелась; пьёт — жажда, вода рядом». Only the selected animal carries a full reason (the
## worker ships it for the inspected one only). A «kept» reason carries the fragments of what it
## goes on doing, so it explains that; the card holds a fresh switch's words a few seconds first.
## Tests build reasons through the real selector, so a change of form fails a test rather than
## leaking English onto the card.

const HudTextScript := preload("res://scripts/ui/hud_text.gd")

## The evaluators' fragment labels (`reason_if()`), strongest two shown; `[he, she]` where the
## word agrees with the animal.
const FRAGMENTS := {
	"thirst": "жажда", "water": "вода рядом", "risk": "у воды опасно", "hunger": "голод",
	"food": "корм рядом", "threat": "угроза", "calm": "спокойно", "scarcity": "мало корма",
	"night": "ночь", "predator": "виден хищник", "open": "открытое место", "prey": "есть добыча",
	"range": "добыча близко", "urgent": ["очень голоден", "очень голодна"], "signal": "следы у воды",
	"alone": ["отбился от стада", "отбилась от стада"], "herd": "свои рядом", "separation": "далеко от пары",
	"mate": "пара рядом", "idle": "нечем заняться", "fatigue": ["устал", "устала"], "safe": "здесь безопасно",
	"carcass": "туша рядом", "meat": "на туше есть мясо",
}
## What an animal stopped doing: `[he, she]`.
const DROPPED := {
	"graze": ["перестал пастись", "перестала пастись"], "drink": ["перестал пить", "перестала пить"],
	"rest": ["перестал отдыхать", "перестала отдыхать"], "explore": ["перестал бродить", "перестала бродить"],
	"join_herd": ["перестал догонять своих", "перестала догонять своих"],
	"flee_to_safe_area": ["перестал убегать", "перестала убегать"], "hunt_prey": ["бросил охоту", "бросила охоту"],
	"scavenge_carcass": ["отошёл от падали", "отошла от падали"], "investigate_water": ["ушёл от воды", "ушла от воды"],
	"pair_cohesion": ["отстал от пары", "отстала от пары"], "patrol": ["бросил обход", "бросила обход"],
	"reproduce": ["перестал искать пару", "перестала искать пару"], "none": ["перестал стоять", "перестала стоять"],
}
## Why it stopped (the evaluators' vetoes, `veto()`): `[he, she]`, by «action|veto» or by veto alone.
const VETOES := {
	"graze|below hunger floor": ["наелся", "наелась"], "hunt_prey|below hunger floor": ["сыт", "сыта"],
	"scavenge_carcass|below hunger floor": ["сыт", "сыта"], "below hunger floor": ["сыт", "сыта"],
	"below thirst floor": ["напился", "напилась"], "below chase energy reserve": ["нет сил на погоню", "нет сил на погоню"],
	"not tired": ["отдохнул", "отдохнула"], "prey in reach": ["рядом добыча", "рядом добыча"],
	"vetoed": ["больше не нужно", "больше не нужно"],
}
## A hunt in progress (`engaged flow: <state>`): `[he, she]`.
const ENGAGED := {
	"seek_prey": ["выслеживает добычу", "выслеживает добычу"], "chase": ["гонится за добычей", "гонится за добычей"],
	"search_last_seen": ["ищет, где видел добычу", "ищет, где видела добычу"], "attack": ["нападает", "нападает"],
	"seek_carcass": ["идёт к туше", "идёт к туше"], "feed_carcass": ["ест добычу", "ест добычу"],
	"investigate_water": ["караулит у воды", "караулит у воды"], "reproduce": ["ищет пару", "ищет пару"],
}


## The reason in words, or "" when it says nothing a player needs: a bare action name (the
## reason before the animal's first decision while selected), no actions, a kept course with no
## reasons of its own. `with_action` names what it is doing before why («пьёт — жажда»); the card,
## which shows the action a line above, asks for the reasons alone.
static func describe(reason: String, sex: String = "", with_action := true) -> String:
	var text := reason.strip_edges()
	if text == "" or text == "no allowed actions":
		return ""
	if text.begins_with("kept "):
		var name_end := text.find(" ", 5)
		var kept_action := text.substr(5, name_end - 5) if name_end > 5 else ""
		var kept_words := _words(_trailing_fragments(text), sex)
		var going_on := str(HudTextScript.ACTIONS.get(kept_action, "")).to_lower()
		if going_on == "" or kept_words.is_empty():
			return ""
		return "%s — %s" % [going_on, ", ".join(kept_words)] if with_action else ", ".join(kept_words)
	if text == "danger or recent threat":
		return "убегает — рядом опасность"
	if text == "reproduction override":
		return "ищет пару — пора продолжить род"
	if text == "engaged flow idle":
		return "переводит дух после охоты"
	if text.begins_with("engaged flow: "):
		return _gendered(ENGAGED.get(text.substr(14), []), sex)
	if text.begins_with("forced interrupt to "):
		var rest := text.find("; ")
		return describe(text.substr(rest + 2), sex, with_action) if rest >= 0 else ""
	var parts: Array = []
	if text.begins_with("dropped "):
		var open := text.find(" (")
		var close := text.find("); ")
		if open < 0 or close < open:
			return ""
		var dropped := text.substr(8, open - 8)
		var veto := text.substr(open + 2, close - open - 2)
		var stopped := _gendered(DROPPED.get(dropped, []), sex)
		var because := _gendered(VETOES.get("%s|%s" % [dropped, veto], VETOES.get(veto, [])), sex)
		if stopped != "":
			parts.append(stopped + (" — " + because if because != "" else ""))
		text = text.substr(close + 3)
		if text.begins_with("forced interrupt to "):
			var rest := text.find("; ")
			text = text.substr(rest + 2) if rest >= 0 else ""
	if text.begins_with("selected "):
		var at := text.find(" at ")
		if at < 0:
			return "; ".join(parts)
		var action := text.substr(9, at - 9)
		var words := _words(_trailing_fragments(text), sex)
		var doing := str(HudTextScript.ACTIONS.get(action, "")).to_lower()
		if doing != "" and not words.is_empty():
			parts.append("%s — %s" % [doing, ", ".join(words)] if with_action else ", ".join(words))
	return "; ".join(parts)


## `[[label, value], …]` from the reason's last bracket, if it holds fragments («thirst 0.80»).
static func _trailing_fragments(text: String) -> Array:
	var fragments: Array = []
	var open := text.rfind(" (")
	if open < 0 or not text.ends_with(")"):
		return fragments
	for fragment in text.substr(open + 2, text.length() - open - 3).split(", "):
		var pieces := str(fragment).rsplit(" ", true, 1)
		if pieces.size() == 2 and pieces[1].is_valid_float():
			fragments.append([pieces[0], float(pieces[1])])
	return fragments


## The two strongest fragments' words.
static func _words(fragments: Array, sex: String) -> Array:
	fragments.sort_custom(func(x, y): return float(x[1]) > float(y[1]))
	var words: Array = []
	for fragment in fragments:
		var known = FRAGMENTS.get(fragment[0], "")
		var word: String = _gendered(known, sex) if known is Array else str(known)
		if word != "" and not words.has(word):
			words.append(word)
		if words.size() >= 2:
			break
	return words


static func _gendered(forms: Array, sex: String) -> String:
	if forms.is_empty():
		return ""
	return str(forms[1] if sex == "female" else forms[0])
