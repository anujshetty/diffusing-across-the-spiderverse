<!--⚠️ Note that this file is in Markdown but contain specific syntax for our doc-builder (similar to MDX) that may not be
rendered properly in your Markdown viewer.
-->

# LoRA for token classification

Low-Rank Adaptation (LoRA) is a reparametrization method that aims to reduce the number of trainable parameters with low-rank representations. The weight matrix is broken down into low-rank matrices that are trained and updated. All the pretrained model parameters remain frozen. After training, the low-rank matrices are added back to the original weights. This makes it more efficient to store and train a LoRA model because there are significantly fewer parameters.

<Tip>

💡 Read [LoRA: Low-Rank Adaptation of Large Language Models](https://arxiv.org/abs/2106.09685) to learn more about LoRA.

</Tip>

This guide will show you how to train a [`roberta-large`](https://huggingface.co/roberta-large) model with LoRA on the [BioNLP2004](https://huggingface.co/datasets/tner/bionlp2004) dataset for token classification.

Before you begin, make sure you have all the necessary libraries installed:

```bash
!pip install -q peft transformers datasets evaluate seqeval
```

## Setup

Let's start by importing all the necessary libraries you'll need:

- 🤗 Transformers for loading the base `roberta-large` model and tokenizer, and handling the training loop
- 🤗 Datasets for loading and preparing the `bionlp2004` dataset for training
- 🤗 Evaluate for evaluating the model's performance
- 🤗 PEFT for setting up the LoRA configuration and creating the PEFT model

```py
from datasets import load_dataset
from transformers import (
    AutoModelForTokenClassification,
    AutoTokenizer,
    DataCollatorForTokenClassification,
    TrainingArguments,
    Trainer,
)
from peft import get_peft_config, PeftModel, PeftConfig, get_peft_model, LoraConfig, TaskType
import evaluate
import torch
import numpy as np

model_checkpoint = "roberta-large"
lr = 1e-3
batch_size = 16
num_epochs = 10
```

## Load dataset and metric

The [BioNLP2004](https://huggingface.co/datasets/tner/bionlp2004) dataset includes tokens and tags for biological structures like DNA, RNA and proteins. Load the dataset:

```py
bionlp = load_dataset("tner/bionlp2004")
bionlp["train"][0]
{
    "tokens": [
        "Since",
        "HUVECs",
        "released",
        "superoxide",
        "anions",
        "in",
        "response",
        "to",
        "TNF",
        ",",
        "and",
        "H2O2",
        "induces",
        "VCAM-1",
        ",",
        "PDTC",
        "may",
        "act",
        "as",
        "a",
        "radical",
        "scavenger",
        ".",
    ],
    "tags": [0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
}
```

The `tags` values are defined in the label ids [dictionary](https://huggingface.co/datasets/tner/bionlp2004#label-id). The letter that prefixes each label indicates the token position: `B` is for the first token of an entity, `I` is for a token inside the entity, and `0` is for a token that is not part of an entity.

```py
{
    "O": 0,
    "B-DNA": 1,
    "I-DNA": 2,
    "B-protein": 3,
    "I-protein": 4,
    "B-cell_type": 5,
    "I-cell_type": 6,
    "B-cell_line": 7,
    "I-cell_line": 8,
    "B-RNA": 9,
    "I-RNA": 10,
}
```

Then load the [`seqeval`](https://huggingface.co/spaces/evaluate-metric/seqeval) framework which includes several metrics - precision, accuracy, F1, and recall - for evaluating sequence labeling tasks.

```py
seqeval = evaluate.load("seqeval")
```

Now you can write an evaluation function to compute the metrics from the model predictions and labels, and return the precision, recall, F1, and accuracy scores:

```py
label_list = [
    "O",
    "B-DNA",
    "I-DNA",
    "B-protein",
    "I-protein",
    "B-cell_type",
    "I-cell_type",
    "B-cell_line",
    "I-cell_line",
    "B-RNA",
    "I-RNA",
]


def compute_metrics(p):
    predictions, labels = p
    predictions = np.argmax(predictions, axis=2)

    true_predictions = [
        [label_list[p] for (p, l) in zip(prediction, label) if l != -100]
        for prediction, label in zip(predictions, labels)
    ]
    true_labels = [
        [label_list[l] for (p, l) in zip(prediction, label) if l != -100]
        for prediction, label in zip(predictions, labels)
    ]

    results = seqeval.compute(predictions=true_predictions, references=true_labels)
    return {
        "precision": results["overall_precision"],
        "recall": results["overall_recall"],
        "f1": results["overall_f1"],
        "accuracy": results["overall_accuracy"],
    }
```

## Preprocess dataset

Initialize a tokenizer and make sure you set `is_split_into_words=True` because the text sequence has already been split into words. However, this doesn't mean it is tokenized yet (even though it may look like it!), and you'll need to further tokenize the words into subwords.

```py
tokenizer = AutoTokenizer.from_pretrained(model_checkpoint, add_prefix_space=True)
```

You'll also need to write a function to:

1. Map each token to their respective word with the [`~transformers.BatchEncoding.word_ids`] method.
2. Ignore the special tokens by setting them to `-100`.
3. Label the first token of a given entity.

```py
def tokenize_and_align_labels(examples):
    tokenized_inputs = tokenizer(examples["tokens"], truncation=True, is_split_into_words=True)

    labels = []
    for i, label in enumerate(examples[f"tags"]):
        word_ids = tokenized_inputs.word_ids(batch_index=i)
        previous_word_idx = None
        label_ids = []
        for word_idx in word_ids:
            if word_idx is None:
                label_ids.append(-100)
            elif word_idx != previous_word_idx:
                label_ids.append(label[word_idx])
            else:
                label_ids.append(-100)
            previous_word_idx = word_idx
        labels.append(label_ids)

    tokenized_inputs["labels"] = labels
    return tokenized_inputs
```

Use [`~datasets.Dataset.map`] to apply the `tokenize_and_align_labels` function to the dataset:

```py
tokenized_bionlp = bionlp.map(tokenize_and_align_labels, batched=True)
```

Finally, create a data collator to pad the examples to the longest length in a batch:

```py
data_collator = DataCollatorForTokenClassification(tokenizer=tokenizer)
```

## Train

Now you're ready to create a [`PeftModel`]. Start by loading the base `roberta-large` model, the number of expected labels, and the `id2label` and `label2id` dictionaries:

```py
id2label = {
    0: "O",
    1: "B-DNA",
    2: "I-DNA",
    3: "B-protein",
    4: "I-protein",
    5: "B-cell_type",
    6: "I-cell_type",
    7: "B-cell_line",
    8: "I-cell_line",
    9: "B-RNA",
    10: "I-RNA",
}
label2id = {
    "O": 0,
    "B-DNA": 1,
    "I-DNA": 2,
    "B-protein": 3,
    "I-protein": 4,
    "B-cell_type": 5,
    "I-cell_type": 6,
    "B-cell_line": 7,
    "I-cell_line": 8,
    "B-RNA": 9,
    "I-RNA": 10,
}

model = AutoModelForTokenClassification.from_pretrained(
    model_checkpoint, num_labels=11, id2label=id2label, label2id=label2id
)
```

Define the [`LoraConfig`] with:

- `task_type`, token classification (`TaskType.TOKEN_CLS`)
- `r`, the dimension of the low-rank matrices
- `lora_alpha`, scaling factor for the weight matrices
- `lora_dropout`, dropout probability of the LoRA layers
- `bias`, set to `all` to train all bias parameters

<Tip>

💡 The weight matrix is scaled by `lora_alpha/r`, and a higher `lora_alpha` value assigns more weight to the LoRA activations. For performance, we recommend setting `bias` to `None` first, and then `lora_only`, before trying `all`.

</Tip>

```py
peft_config = LoraConfig(
    task_type=TaskType.TOKEN_CLS, inference_mode=False, r=16, lora_alpha=16, lora_dropout=0.1, bias="all"
)
```

Pass the base model and `peft_config` to the [`get_peft_model`] function to create a [`PeftModel`]. You can check out how much more efficient training the [`PeftModel`] is compared to fully training the base model by printing out the trainable parameters:

```py
model = get_peft_model(model, peft_config)
model.print_trainable_parameters()
"trainable params: 1855499 || all params: 355894283 || trainable%: 0.5213624069370061"
```

From the 🤗 Transformers library, create a [`~transformers.TrainingArguments`] class and specify where you want to save the model to, the training hyperparameters, how to evaluate the model, and when to save the checkpoints:

```py
training_args = TrainingArguments(
    output_dir="roberta-large-lora-token-classification",
    learning_rate=lr,
    per_device_train_batch_size=batch_size,
    per_device_eval_batch_size=batch_size,
    num_train_epochs=num_epochs,
    weight_decay=0.01,
    evaluation_strategy="epoch",
    save_strategy="epoch",
    load_best_model_at_end=True,
)
```

Pass the model, `TrainingArguments`, datasets, tokenizer, data collator and evaluation function to the [`~transformers.Trainer`] class. The `Trainer` handles the training loop for you, and when you're ready, call [`~transformers.Trainer.train`] to begin!

```py
trainer = Trainer(
    model=model,
    args=training_args,
    train_dataset=tokenized_bionlp["train"],
    eval_dataset=tokenized_bionlp["validation"],
    tokenizer=tokenizer,
    data_collator=data_collator,
    compute_metrics=compute_metrics,
)

trainer.train()
```

## Share model

Once training is complete, you can store and share your model on the Hub if you'd like. Log in to your Hugging Face account and enter your token when prompted:

```py
from huggingface_hub import notebook_login

notebook_login()
```

Upload the model to a specific model repository on the Hub with the [`~transformers.PreTrainedModel.push_to_hub`] method:

```py
model.push_to_hub("your-name/roberta-large-lora-token-classification")
```

## Inference

To use your model for inference, load the configuration and model:

```py
peft_model_id = "stevhliu/roberta-large-lora-token-classification"
config = PeftConfig.from_pretrained(peft_model_id)
inference_model = AutoModelForTokenClassification.from_pretrained(
    config.base_model_name_or_path, num_labels=11, id2label=id2label, label2id=label2id
)
tokenizer = AutoTokenizer.from_pretrained(config.base_model_name_or_path)
model = PeftModel.from_pretrained(inference_model, peft_model_id)
```

Get some text to tokenize:

```py
text = "The activation of IL-2 gene expression and NF-kappa B through CD28 requires reactive oxygen production by 5-lipoxygenase."
inputs = tokenizer(text, return_tensors="pt")
```

Pass the inputs to the model, and print out the model prediction for each token:

```py
with torch.no_grad():
    logits = model(**inputs).logits

tokens = inputs.tokens()
predictions = torch.argmax(logits, dim=2)

for token, prediction in zip(tokens, predictions[0].numpy()):
    print((token, model.config.id2label[prediction]))
("<s>", "O")
("The", "O")
("Ġactivation", "O")
("Ġof", "O")
("ĠIL", "B-DNA")
("-", "O")
("2", "I-DNA")
("Ġgene", "O")
("Ġexpression", "O")
("Ġand", "O")
("ĠNF", "B-protein")
("-", "O")
("k", "I-protein")
("appa", "I-protein")
("ĠB", "I-protein")
("Ġthrough", "O")
("ĠCD", "B-protein")
("28", "I-protein")
("Ġrequires", "O")
("Ġreactive", "O")
("Ġoxygen", "O")
("Ġproduction", "O")
("Ġby", "O")
("Ġ5", "B-protein")
("-", "O")
("lip", "I-protein")
("oxy", "I-protein")
("gen", "I-protein")
("ase", "I-protein")
(".", "O")
("</s>", "O")
```