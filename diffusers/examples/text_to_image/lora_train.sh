accelerate launch --num_processes=10 train_text_to_image_lora.py \
  --pretrained_model_name_or_path=$MODEL_NAME \
  --train_data_dir=$DATA_DIR \
  --resolution=512 --center_crop --random_flip \
  --train_batch_size=1  \
  --max_train_steps=6000 \
  --learning_rate=1e-05 \
  --max_grad_norm=1 \
  --output_dir=$OUT_DIR \
  --lr_scheduler="cosine" --lr_warmup_steps=0 \
  --checkpointing_steps=50 --report_to=wandb \
#  --validation-prompt="'Earth-65 animation style'"

