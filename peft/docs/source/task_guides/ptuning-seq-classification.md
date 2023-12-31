<!--⚠️ Note that this file is in Markdown but contain specific syntax for our doc-builder (similar to MDX) that may not be
rendered properly in your Markdown viewer.
-->

# P-tuning for sequence classification

It is challenging to finetune large language models for downstream tasks because they have so many parameters. To work around this, you can use *prompts* to steer the model toward a particular downstream task without fully finetuning a model. Typically, these prompts are handcrafted, which may be impractical because you need very large validation sets to find the best prompts. *P-tuning* is a method for automatically searching and optimizing for better prompts in a continuous space.

<Tip>

💡 Read [GPT Understands, Too](https://arxiv.org/abs/2103.10385) to learn more about p-tuning.

</Tip>

This guide will show you how to train a [`roberta-large`](https://huggingface.co/roberta-large) model (but you can also use any of the GPT, OPT, or BLOOM models) with p-tuning on the `mrpc` configuration of the [GLUE](https://huggingface.co/datasets/glue) benchmark.

Before you begin, make sure you have all the necessary libraries installed:

```bash
!pip install -q peft transformers datasets evaluate
```

## Setup

To get started, import 🤗 Transformers to create the base model, 🤗 Datasets to load a dataset, 🤗 Evaluate to load an evaluation metric, and 🤗 PEFT to create a [`PeftModel`] and setup the configuration for p-tuning.

Define the model, dataset, and some basic training hyperparameters:

```py
from transformers import (
    AutoModelForSequenceClassification,
    AutoTokenizer,
    DataCollatorWithPadding,
    TrainingArguments,
    Trainer,
)
from peft import (
    get_peft_config,
    get_peft_model,
    get_peft_model_state_dict,
    set_peft_model_state_dict,
    PeftType,
    PromptEncoderConfig,
)
from datasets import load_dataset
import evaluate
import torch

model_name_or_path = "roberta-large"
task = "mrpc"
num_epochs = 20
lr = 1e-3
batch_size = 32
```

## Load dataset and metric

Next, load the `mrpc` configuration - a corpus of sentence pairs labeled according to whether they're semantically equivalent or not - from the [GLUE](https://huggingface.co/datasets/glue) benchmark:

```py
dataset = load_dataset("glue", task)
dataset["train"][0]
{
    "sentence1": 'Amrozi accused his brother , whom he called " the witness " , of deliberately distorting his evidence .',
    "sentence2": 'Referring to him as only " the witness " , Amrozi accused his brother of deliberately distorting his evidence .',
    "label": 1,
    "idx": 0,
}
```

From 🤗 Evaluate, load a metric for evaluating the model's performance. The evaluation module returns the accuracy and F1 scores associated with this specific task.

```py
metric = evaluate.load("glue", task)
```

Now you can use the `metric` to write a function that computes the accuracy and F1 scores. The `compute_metric` function calculates the scores from the model predictions and labels:

```py
import numpy as np


def compute_metrics(eval_pred):
    predictions, labels = eval_pred
    predictions = np.argmax(predictions, axis=1)
    return metric.compute(predictions=predictions, references=labels)
```

## Preprocess dataset

Initialize the tokenizer and configure the padding token to use. If you're using a GPT, OPT, or BLOOM model, you should set the `padding_side` to the left; otherwise it'll be set to the right. Tokenize the sentence pairs and truncate them to the maximum length.

```py
if any(k in model_name_or_path for k in ("gpt", "opt", "bloom")):
    padding_side = "left"
else:
    padding_side = "right"

tokenizer = AutoTokenizer.from_pretrained(model_name_or_path, padding_side=padding_side)
if getattr(tokenizer, "pad_token_id") is None:
    tokenizer.pad_token_id = tokenizer.eos_token_id


def tokenize_function(examples):
    # max_length=None => use the model max length (it's actually the default)
    outputs = tokenizer(examples["sentence1"], examples["sentence2"], truncation=True, max_length=None)
    return outputs
```

Use [`~datasets.Dataset.map`] to apply the `tokenize_function` to the dataset, and remove the unprocessed columns because the model won't need those. You should also rename the `label` column to `labels` because that is the expected name for the labels by models in the 🤗 Transformers library.

```py
tokenized_datasets = dataset.map(
    tokenize_function,
    batched=True,
    remove_columns=["idx", "sentence1", "sentence2"],
)

tokenized_datasets = tokenized_datasets.rename_column("label", "labels")
```

Create a collator function with [`~transformers.DataCollatorWithPadding`] to pad the examples in the batches to the `longest` sequence in the batch:

```py
data_collator = DataCollatorWithPadding(tokenizer=tokenizer, padding="longest")
```

## Train

P-tuning uses a prompt encoder to optimize the prompt parameters, so you'll need to initialize the [`PromptEncoderConfig`] with several arguments:

- `task_type`: the type of task you're training on, in this case it is sequence classification or `SEQ_CLS`
- `num_virtual_tokens`: the number of virtual tokens to use, or in other words, the prompt
- `encoder_hidden_size`: the hidden size of the encoder used to optimize the prompt parameters

```py
peft_config = PromptEncoderConfig(task_type="SEQ_CLS", num_virtual_tokens=20, encoder_hidden_size=128)
```

Create the base `roberta-large` model from [`~transformers.AutoModelForSequenceClassification`], and then wrap the base model and `peft_config` with [`get_peft_model`] to create a [`PeftModel`]. If you're curious to see how many parameters you're actually training compared to training on all the model parameters, you can print it out with [`~peft.PeftModel.print_trainable_parameters`]:

```py
model = AutoModelForSequenceClassification.from_pretrained(model_name_or_path, return_dict=True)
model = get_peft_model(model, peft_config)
model.print_trainable_parameters()
"trainable params: 1351938 || all params: 355662082 || trainable%: 0.38011867680626127"
```

From the 🤗 Transformers library, set up the [`~transformers.TrainingArguments`] class with where you want to save the model to, the training hyperparameters, how to evaluate the model, and when to save the checkpoints:

```py
training_args = TrainingArguments(
    output_dir="your-name/roberta-large-peft-p-tuning",
    learning_rate=1e-3,
    per_device_train_batch_size=32,
    per_device_eval_batch_size=32,
    num_train_epochs=2,
    weight_decay=0.01,
    evaluation_strategy="epoch",
    save_strategy="epoch",
    load_best_model_at_end=True,
)
```

Then pass the model, `TrainingArguments`, datasets, tokenizer, data collator, and evaluation function to the [`~transformers.Trainer`] class, which'll handle the entire training loop for you. Once you're ready, call [`~transformers.Trainer.train`] to start training!

```py
trainer = Trainer(
    model=model,
    args=training_args,
    train_dataset=tokenized_datasets["train"],
    eval_dataset=tokenized_datasets["test"],
    tokenizer=tokenizer,
    data_collator=data_collator,
    compute_metrics=compute_metrics,
)

trainer.train()
```

## Share model

You can store and share your model on the Hub if you'd like. Log in to your Hugging Face account and enter your token when prompted:

```py
from huggingface_hub import notebook_login

notebook_login()
```

Upload the model to a specifc model repository on the Hub with the [`~transformers.PreTrainedModel.push_to_hub`] function:

```py
model.push_to_hub("your-name/roberta-large-peft-p-tuning", use_auth_token=True)
```

## Inference

Once the model has been uploaded to the Hub, anyone can easily use it for inference. Load the configuration and model:

```py
import torch
from peft import PeftModel, PeftConfig
from transformers import AutoModelForSequenceClassification, AutoTokenizer

peft_model_id = "smangrul/roberta-large-peft-p-tuning"
config = PeftConfig.from_pretrained(peft_model_id)
inference_model = AutoModelForSequenceClassification.from_pretrained(config.base_model_name_or_path)
tokenizer = AutoTokenizer.from_pretrained(config.base_model_name_or_path)
model = PeftModel.from_pretrained(inference_model, peft_model_id)
```

Get some text and tokenize it:

```py
classes = ["not equivalent", "equivalent"]

sentence1 = "Coast redwood trees are the tallest trees on the planet and can grow over 300 feet tall."
sentence2 = "The coast redwood trees, which can attain a height of over 300 feet, are the tallest trees on earth."

inputs = tokenizer(sentence1, sentence2, truncation=True, padding="longest", return_tensors="pt")
```

Pass the inputs to the model to classify the sentences:

```py
with torch.no_grad():
    outputs = model(**inputs).logits
    print(outputs)

paraphrased_text = torch.softmax(outputs, dim=1).tolist()[0]
for i in range(len(classes)):
    print(f"{classes[i]}: {int(round(paraphrased_text[i] * 100))}%")
"not equivalent: 4%"
"equivalent: 96%"
```