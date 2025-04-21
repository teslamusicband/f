#!/bin/bash

# Скрипт для увеличения репликационного фактора всех топиков в Kafka кластере до 3
# Для кластера: srv1.company.com:9099, srv2.company.com:9099, srv3.company.com:9099

# Проверка наличия утилиты kafka-topics
if ! command -v kafka-topics.sh &> /dev/null; then
    echo "ОШИБКА: kafka-topics.sh не найден. Убедитесь, что он в PATH или укажите полный путь."
    exit 1
fi

# Проверка наличия утилиты jq
if ! command -v jq &> /dev/null; then
    echo "ОШИБКА: jq не установлен. Установите с помощью apt-get install jq или yum install jq"
    exit 1
fi

# Конфигурация кластера
BOOTSTRAP_SERVERS="srv1.company.com:9099,srv2.company.com:9099,srv3.company.com:9099"
TEMP_FILE="/tmp/reassignment-$(date +%s).json"
FINAL_PLAN="/tmp/reassignment-plan-$(date +%s).json"
BROKER_LIST="1,2,3"

echo "Начинаю процесс увеличения репликационного фактора для всех топиков..."

# Получаем список всех топиков
TOPICS=$(kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVERS --list)

if [ $? -ne 0 ]; then
    echo "ОШИБКА: Не удалось получить список топиков."
    exit 1
fi

echo "Найдено топиков: $(echo "$TOPICS" | wc -l)"

# Создаём план реассайнмента для всех топиков
echo '{
  "version": 1,
  "topics": [' > $TEMP_FILE

first_topic=true

for topic in $TOPICS; do
    # Пропускаем внутренние топики Kafka, начинающиеся с _
    if [[ $topic == _* ]]; then
        echo "Пропускаю внутренний топик: $topic"
        continue
    fi
    
    # Получаем информацию о топике в формате JSON
    topic_info=$(kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVERS --describe --topic $topic --format json)
    
    # Если это не первый топик в файле, добавляем запятую
    if [ "$first_topic" = false ]; then
        echo "," >> $TEMP_FILE
    else
        first_topic=false
    fi
    
    # Извлекаем количество партиций топика
    partition_count=$(echo "$topic_info" | jq -r '.partitions | length')
    
    echo "Обрабатываю топик: $topic ($partition_count партиций)"
    
    # Формируем JSON для реассайнмента партиций этого топика
    echo '    {
      "topic": "'$topic'",
      "partitions": [' >> $TEMP_FILE
    
    for i in $(seq 0 $(($partition_count - 1))); do
        if [ $i -gt 0 ]; then
            echo "," >> $TEMP_FILE
        fi
        
        echo '        {
          "partition": '$i',
          "replicas": [1, 2, 3]
        }' >> $TEMP_FILE
    done
    
    echo '      ]
    }' >> $TEMP_FILE
done

echo '  ]
}' >> $TEMP_FILE

# Генерация финального плана реассайнмента с помощью Kafka утилиты
echo "Генерируем план реассайнмента..."
kafka-reassign-partitions.sh --bootstrap-server $BOOTSTRAP_SERVERS \
    --reassignment-json-file $TEMP_FILE \
    --generate > $FINAL_PLAN

if [ $? -ne 0 ]; then
    echo "ОШИБКА: Не удалось сгенерировать план реассайнмента."
    exit 1
fi

# Извлекаем сгенерированный JSON план из вывода команды
cat $FINAL_PLAN | grep -A 100000 "Proposed partition" | grep -v "Proposed partition" > /tmp/proposed.json

echo "План реассайнмента создан: /tmp/proposed.json"
echo "Выполняем реассайнмент..."

# Запускаем реассайнмент
kafka-reassign-partitions.sh --bootstrap-server $BOOTSTRAP_SERVERS \
    --reassignment-json-file /tmp/proposed.json \
    --execute

if [ $? -ne 0 ]; then
    echo "ОШИБКА: Не удалось запустить реассайнмент."
    exit 1
fi

echo "Реассайнмент запущен! Проверяйте статус с помощью команды:"
echo "kafka-reassign-partitions.sh --bootstrap-server $BOOTSTRAP_SERVERS --reassignment-json-file /tmp/proposed.json --verify"
echo ""
echo "Примечание: Процесс реассайнмента может занять время, зависит от размера данных в топиках."
echo "Рекомендуется периодически проверять статус выполнения."

# Очистка временных файлов
rm $TEMP_FILE
