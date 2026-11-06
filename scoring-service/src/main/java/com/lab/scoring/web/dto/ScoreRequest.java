package com.lab.scoring.web.dto;

import jakarta.validation.constraints.NotBlank;

public record ScoreRequest(@NotBlank String customerId) {
}
