---
title: 'Grammar Error Correction Model'
author: martin
date: 2026-01-09
description: 'Researching on-device grammar correction models for Mochi Keyboard - part 1 of my GEC journey'
tags: ["GEC", "machine learning", "NLP", "Mochi Keyboard", "on-device AI"]
---

I want to build a grammar checker inside that work inside a keyboard extension. I wanted to build one for a few years now. It's a very /una tarea muy dificil/ 

been absolutely obsessed with Grammar Error Correction (GEC) models for the last few months, and it's been this wild rollercoaster of frustration and excitement. Let me tell you about it.

## The Idea

Picture this: you're typing on your phone, and instead of just autocorrecting spelling, the keyboard actually fixes your grammar in real-time. Like, "I go to school yesterday" becomes "I went to school yesterday" without you even noticing. And it does this all on-device, no data sent to any server, because privacy matters.

That's the vision for Mochi Keyboard. A tiny model (~20MB) that teaches you grammar as you type. But holy shit, getting there is hard.

## The Landscape

Everyone benchmarks on BEA-2019, this dataset from 2019 that measures how well you fix grammatical errors. The metric is F0.5 - precision matters twice as much as recall, because it's better to not fix than to fix wrong.

Current sota is like 75% F0.5, but those models are 1-3GB. Too big for phones. On-device stuff hovers around 50% with tiny models. The gap is huge.

## My Approach

I'm not doing the usual seq2seq (generate whole new sentence). Instead, I'm tagging: the model predicts operations per token.

Like:
```
Input: "I go to school yesterday"
Tags:  [KEEP][REPLACE:went][KEEP][KEEP][KEEP]
```

It's more efficient for on-device. No generating entire sentences.

### gec-t5 Baseline
Started by reproducing what everyone else does. Took gec-t5 (T5 fine-tuned on cLang-8) and got it working locally. 55% F0.5 with base model, 60% with large. Great! But 3GB is not happening on phones.

### Diffusion Models
This was a rabbit hole. I got obsessed with diffusion language models. Trained Qwen3-0.6B-diffusion on GEC data and holy shit, it got to 51% F0.5 with just 0.6B parameters. That's competitive with much larger seq2seq models!

The bidirectional nature of diffusion seems perfect for text correction - you can change things in any direction.

### TRM-GEC: My Tiny Model
This is the one I'm most excited about. Based on this paper "Less is More: Recursive Reasoning with Tiny Networks", I built a tiny model (~14M params, ~22MB) that uses recursion instead of deep layers.

It's trained from scratch, no pretrained embeddings, and it hit 23% F0.5. Not amazing, but for a model that small with no prior knowledge? That's something.

The problem is class imbalance: 95% of tokens are "KEEP", so it rarely corrects. I'm trying a two-head approach now: one head decides what operation (keep/replace/delete), another decides what word. Hopefully that fixes the imbalance.

### SEDD Experiments
Another diffusion approach. Got some cool corrections but the model started outputting random Japanese characters. Fine-tuning too aggressive, corrupted the token distribution. Interesting failure though.

## The Dataset Mess

This is driving me nuts. Everyone uses cLang-8 for training, but it says "not for commercial use". Yet Grammarly clearly has a commercial GEC product. What the hell? Are they using different data? Synthetic stuff? I don't get it.

For now I'm mixing:
- cLang-8 (research only, I assume)
- CoEdIT (clean, Apache 2.0)
- C4_200M (synthetic data)

## Working with LLMs

This whole thing is only possible because of Claude Opus. I delegate most of the implementation to the LLM - "write me a training script for diffusion GEC" - and it just does it. Speeds everything up insanely.

But it's tricky. Context limits mean I have to structure projects carefully. Bugs happen when I don't. The speed makes me sloppy sometimes. It's a whole new way of coding.

## What's Next

1. Finish the two-head TRM experiment
2. Try subword-level tagging with GPT-2 embeddings
3. Maybe go back to diffusion - that 51% result was intriguing
4. Figure out the dataset licensing thing

Goal: 45%+ F0.5 in <25MB. We're not there yet, but it's getting closer.

---

*This is part 1 of me rambling about GEC research. If this is boring, let me know what you'd rather hear about.*
