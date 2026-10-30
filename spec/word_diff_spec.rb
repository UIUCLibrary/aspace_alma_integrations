require 'spec_helper'

RSpec.describe AlmaIntegrations::WordDiff do

  def texts(segments)
    segments.map { |segment| segment['text'] }
  end

  def changed(segments)
    segments.select { |segment| segment['changed'] }.map { |segment| segment['text'] }
  end

  it 'marks nothing when the values are identical' do
    left, right = described_class.call('Floor Plans', 'Floor Plans')

    expect(changed(left)).to be_empty
    expect(changed(right)).to be_empty
  end

  it 'rebuilds each side exactly, whitespace and all' do
    before = "  Sanskrit:  \u0915\u093E\u091A\u0902\tGreek: \u1F55\u03B1\u03BB\u03BF\u03BD  "
    after = "  Sanskrit:  \u0915\u093E\u091A\u0902\tLatin: Vitrum  "

    left, right = described_class.call(before, after)

    expect(texts(left).join).to eq(before)
    expect(texts(right).join).to eq(after)
  end

  it 'marks only the words that differ' do
    left, right = described_class.call('Floor Plans, Architectural', 'Floor Plans')

    expect(changed(left)).to eq([', Architectural'])
    expect(changed(right)).to be_empty
  end

  it 'marks an insertion in the middle without disturbing either end' do
    left, right = described_class.call('Buildings and Section', 'Buildings and Equipment Section')

    expect(changed(left)).to be_empty
    expect(changed(right)).to eq(['Equipment '])
  end

  it 'marks a replacement on both sides, down to the digits that differ' do
    left, right = described_class.call('Added 5.0 cu. ft. on 9/12/07', 'Added 12.0 cu. ft. on 9/12/07')

    expect(changed(left)).to eq(['5'])
    expect(changed(right)).to eq(['12'])
  end

  it 'marks changed punctuation without marking the word it hangs off' do
    left, right = described_class.call('Armour, Philip D.,', 'Armour, Philip D.')

    # The whole run of trailing punctuation is one token, so the mark covers
    # '.,' rather than just the added comma. The name either side of it is
    # left alone, which is the point.
    expect(changed(left)).to eq(['.,'])
    expect(changed(right)).to eq(['.'])
  end

  it 'handles one side being empty' do
    left, right = described_class.call('', 'Test arrangement statement.')

    expect(left).to be_empty
    expect(texts(right).join).to eq('Test arrangement statement.')
    expect(changed(right)).to eq(['Test arrangement statement.'])
  end

  it 'still produces a usable result when the values are too large to align word by word' do
    before = (1..800).map { |n| "word#{n}" }.join(' ')
    after = (1..800).map { |n| "other#{n}" }.join(' ')

    left, right = described_class.call(before, after)

    expect(texts(left).join).to eq(before)
    expect(texts(right).join).to eq(after)
    expect(changed(left).join).to eq(before)
  end

  it 'does not fall back when a long value was only edited in one place' do
    body = (1..800).map { |n| "word#{n}" }.join(' ')
    left, right = described_class.call("#{body} tail", "#{body} changed")

    expect(changed(left)).to eq(['tail'])
    expect(changed(right)).to eq(['changed'])
  end

  it 'treats a value that only changed in whitespace as a change to that whitespace alone' do
    left, right = described_class.call("English ,  German", "English , German")

    expect(texts(left).join).to eq("English ,  German")
    expect(texts(right).join).to eq("English , German")
    expect(changed(left)).not_to be_empty
  end
end
