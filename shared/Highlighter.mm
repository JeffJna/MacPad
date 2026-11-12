// Syntax highlighting without Scintilla.
// This file is part of MacPad (GPL v3 or later).
#include "Highlighter.h"

#include <algorithm>
#include <cstring>

#include "ILexer.h"
#include "Lexilla.h"
#include "Scintilla.h"

#include "LanguageCatalog.h"

namespace
{

// The part of a Scintilla document that lexers use: text, styles, line starts, fold levels
// and line states.
class LexDocument : public Scintilla::IDocument
{
public:
	explicit LexDocument(const std::string &text) : _text(text), _styles(text.size(), 0)
	{
		_lineStarts.push_back(0);
		for (size_t i = 0; i < _text.size(); ++i)
		{
			const char c = _text[i];
			if (c == '\n' || (c == '\r' && (i + 1 >= _text.size() || _text[i + 1] != '\n')))
				_lineStarts.push_back(static_cast<Sci_Position>(i + 1));
		}
		_levels.assign(_lineStarts.size(), SC_FOLDLEVELBASE);
		_states.assign(_lineStarts.size(), 0);
	}

	std::vector<unsigned char> TakeStyles() { return std::move(_styles); }

	int SCI_METHOD Version() const override { return Scintilla::dvRelease4; }
	void SCI_METHOD SetErrorStatus(int) override {}
	Sci_Position SCI_METHOD Length() const override { return static_cast<Sci_Position>(_text.size()); }

	void SCI_METHOD GetCharRange(char *buffer, Sci_Position position, Sci_Position length) const override
	{
		for (Sci_Position i = 0; i < length; ++i)
		{
			const Sci_Position at = position + i;
			buffer[i] = at >= 0 && at < Length() ? _text[static_cast<size_t>(at)] : '\0';
		}
	}

	char SCI_METHOD StyleAt(Sci_Position position) const override
	{
		return position >= 0 && position < Length() ? static_cast<char>(_styles[static_cast<size_t>(position)]) : 0;
	}

	Sci_Position SCI_METHOD LineFromPosition(Sci_Position position) const override
	{
		if (position <= 0)
			return 0;
		const auto found = std::upper_bound(_lineStarts.begin(), _lineStarts.end(), position);
		return static_cast<Sci_Position>(found - _lineStarts.begin()) - 1;
	}

	Sci_Position SCI_METHOD LineStart(Sci_Position line) const override
	{
		if (line <= 0)
			return 0;
		if (line >= static_cast<Sci_Position>(_lineStarts.size()))
			return Length();
		return _lineStarts[static_cast<size_t>(line)];
	}

	Sci_Position SCI_METHOD LineEnd(Sci_Position line) const override
	{
		if (line < 0)
			return 0;
		if (line + 1 >= static_cast<Sci_Position>(_lineStarts.size()))
			return Length();
		Sci_Position end = _lineStarts[static_cast<size_t>(line + 1)];
		const Sci_Position start = LineStart(line);
		if (end > start && _text[static_cast<size_t>(end - 1)] == '\n')
			--end;
		if (end > start && _text[static_cast<size_t>(end - 1)] == '\r')
			--end;
		return end;
	}

	int SCI_METHOD GetLevel(Sci_Position line) const override
	{
		return line >= 0 && line < static_cast<Sci_Position>(_levels.size()) ? _levels[static_cast<size_t>(line)] : SC_FOLDLEVELBASE;
	}

	int SCI_METHOD SetLevel(Sci_Position line, int level) override
	{
		if (line < 0 || line >= static_cast<Sci_Position>(_levels.size()))
			return SC_FOLDLEVELBASE;
		const int previous = _levels[static_cast<size_t>(line)];
		_levels[static_cast<size_t>(line)] = level;
		return previous;
	}

	int SCI_METHOD GetLineState(Sci_Position line) const override
	{
		return line >= 0 && line < static_cast<Sci_Position>(_states.size()) ? _states[static_cast<size_t>(line)] : 0;
	}

	int SCI_METHOD SetLineState(Sci_Position line, int state) override
	{
		if (line < 0 || line >= static_cast<Sci_Position>(_states.size()))
			return 0;
		const int previous = _states[static_cast<size_t>(line)];
		_states[static_cast<size_t>(line)] = state;
		return previous;
	}

	void SCI_METHOD StartStyling(Sci_Position position) override
	{
		_endStyled = std::clamp<Sci_Position>(position, 0, Length());
	}

	bool SCI_METHOD SetStyleFor(Sci_Position length, char style) override
	{
		const Sci_Position end = std::min(_endStyled + std::max<Sci_Position>(length, 0), Length());
		std::fill(_styles.begin() + _endStyled, _styles.begin() + end, static_cast<unsigned char>(style));
		_endStyled = end;
		return true;
	}

	bool SCI_METHOD SetStyles(Sci_Position length, const char *styles) override
	{
		for (Sci_Position i = 0; i < length && _endStyled < Length(); ++i)
			_styles[static_cast<size_t>(_endStyled++)] = static_cast<unsigned char>(styles[i]);
		return true;
	}

	void SCI_METHOD DecorationSetCurrentIndicator(int) override {}
	void SCI_METHOD DecorationFillRange(Sci_Position, int, Sci_Position) override {}
	void SCI_METHOD ChangeLexerState(Sci_Position, Sci_Position) override {}
	int SCI_METHOD CodePage() const override { return SC_CP_UTF8; }
	bool SCI_METHOD IsDBCSLeadByte(char) const override { return false; }
	const char *SCI_METHOD BufferPointer() override { return _text.c_str(); }

	int SCI_METHOD GetLineIndentation(Sci_Position line) override
	{
		int indent = 0;
		for (Sci_Position i = LineStart(line); i < LineEnd(line); ++i)
		{
			const char c = _text[static_cast<size_t>(i)];
			if (c == ' ')
				++indent;
			else if (c == '\t')
				indent = (indent / 8 + 1) * 8;
			else
				break;
		}
		return indent;
	}

	Sci_Position SCI_METHOD GetRelativePosition(Sci_Position start, Sci_Position offset) const override
	{
		Sci_Position position = start;
		for (; offset > 0; --offset)
		{
			if (position >= Length())
				return -1;
			++position;
			while (position < Length() && IsContinuation(position))
				++position;
		}
		for (; offset < 0; ++offset)
		{
			if (position <= 0)
				return -1;
			--position;
			while (position > 0 && IsContinuation(position))
				--position;
		}
		return position;
	}

	int SCI_METHOD GetCharacterAndWidth(Sci_Position position, Sci_Position *width) const override
	{
		if (position < 0 || position >= Length())
		{
			if (width)
				*width = 1;
			return 0;
		}
		const unsigned char lead = static_cast<unsigned char>(_text[static_cast<size_t>(position)]);
		int length = 1;
		int value = lead;
		if (lead >= 0xF0)
		{
			length = 4;
			value = lead & 0x07;
		}
		else if (lead >= 0xE0)
		{
			length = 3;
			value = lead & 0x0F;
		}
		else if (lead >= 0xC0)
		{
			length = 2;
			value = lead & 0x1F;
		}
		if (length > 1)
		{
			for (int i = 1; i < length; ++i)
			{
				if (position + i >= Length() || !IsContinuation(position + i))
				{
					// Not valid UTF-8: one byte, as Scintilla treats it.
					if (width)
						*width = 1;
					return lead;
				}
				value = (value << 6) | (static_cast<unsigned char>(_text[static_cast<size_t>(position + i)]) & 0x3F);
			}
		}
		if (width)
			*width = length;
		return value;
	}

private:
	bool IsContinuation(Sci_Position position) const
	{
		return (static_cast<unsigned char>(_text[static_cast<size_t>(position)]) & 0xC0) == 0x80;
	}

	const std::string &_text;
	std::vector<unsigned char> _styles;
	std::vector<Sci_Position> _lineStarts;
	std::vector<int> _levels;
	std::vector<int> _states;
	Sci_Position _endStyled = 0;
};

} // namespace

std::vector<unsigned char> StyleText(const std::string &utf8, const Language &language)
{
	Scintilla::ILexer5 *lexer = language.lexer == "null" ? nullptr : CreateLexer(language.lexer.c_str());
	if (!lexer)
		return std::vector<unsigned char>(utf8.size(), 0);
	for (const auto &[key, value] : language.properties)
		lexer->PropertySet(key.c_str(), value.c_str());
	for (int set = 0; set < KW_COUNT; ++set)
	{
		if (!language.keywords[set].empty())
			lexer->WordListSet(set, language.keywords[set].c_str());
	}
	LexDocument document(utf8);
	lexer->Lex(0, static_cast<Sci_Position>(utf8.size()), 0, &document);
	lexer->Release();
	return document.TakeStyles();
}
